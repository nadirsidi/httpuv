#' HTTP and WebSocket server
#'
#' Allows R code to listen for and interact with HTTP and WebSocket clients, so
#' you can serve web traffic directly out of your R process. Implementation is
#' based on \href{https://github.com/joyent/libuv}{libuv} and
#' \href{https://github.com/joyent/http-parser}{http-parser}.
#'
#' This is a low-level library that provides little more than network I/O and
#' implementations of the HTTP and WebSocket protocols. For an easy way to
#' create web applications, try \href{http://rstudio.com/shiny/}{Shiny} instead.
#'
#' @examples
#' \dontrun{
#' demo("echo", package="httpuv")
#' }
#'
#' @seealso \link{startServer}
#'
#' @name httpuv-package
#' @aliases httpuv
#' @docType package
#' @title HTTP and WebSocket server
#' @author Joe Cheng \email{joe@@rstudio.com}
#' @keywords package
NULL

# Implementation of Rook input stream
InputStream <- R6::R6Class(
  'InputStream',
  public = list(
    initialize = function(conn, length) {
      private$conn <- conn
      private$length <- length
      seek(private$conn, 0)
    },
    read_lines = function(n = -1L) {
      readLines(private$conn, n, warn = FALSE)
    },
    read = function(l = -1L) {
      # l < 0 means read all remaining bytes
      if (l < 0)
        l <- private$length - seek(private$conn)

      if (l == 0)
        return(raw())
      else
        return(readBin(private$conn, raw(), l))
    },
    rewind = function() {
      seek(private$conn, 0)
    }
  ),
  private = list(
    conn = NULL,
    length = NULL
  ),
  cloneable = FALSE
)

NullInputStream <- R6::R6Class(
  'NullInputStream',
  public = list(
    read_lines = function(n = -1L) {
      character()
    },
    read = function(l = -1L) {
      raw()
    },
    rewind = function() invisible(),
    close = function() invisible()
  ),
  cloneable = FALSE
)
nullInputStream <- NullInputStream$new()

#Implementation of Rook error stream
ErrorStream <- R6::R6Class(
  'ErrorStream',
  public = list(
    cat = function(... , sep = " ", fill = FALSE, labels = NULL) {
      base::cat(..., sep=sep, fill=fill, labels=labels, file=stderr())
    },
    flush = function() {
      base::flush(stderr())
    }
  ),
  cloneable = FALSE
)
stdErrStream <- ErrorStream$new()

#' @importFrom promises promise then finally is.promise %...>% %...!%
rookCall <- function(func, req, data = NULL, dataLength = -1) {

  # Break the processing into two parts: first, the computation with func();
  # second, the preparation of the response object.
  compute <- function() {
    inputStream <- if(is.null(data))
      nullInputStream
    else
      InputStream$new(data, dataLength)

    req$rook.input <- inputStream

    req$rook.errors <- stdErrStream

    req$httpuv.version <- httpuv_version()

    # These appear to be required for Rook multipart parsing to work
    if (!is.null(req$HTTP_CONTENT_TYPE))
      req$CONTENT_TYPE <- req$HTTP_CONTENT_TYPE
    if (!is.null(req$HTTP_CONTENT_LENGTH))
      req$CONTENT_LENGTH <- req$HTTP_CONTENT_LENGTH

    # func() may return a regular value or a promise.
    func(req)
  }

  prepare_response <- function(resp) {
    if (is.null(resp) || length(resp) == 0)
      return(NULL)

    # Coerce all headers to character
    resp$headers <- lapply(resp$headers, paste)

    if ('file' %in% names(resp$body)) {
      filename <- resp$body[['file']]
      owned <- FALSE
      if ('owned' %in% names(resp$body))
        owned <- as.logical(resp$body$owned)

      resp$body <- NULL
      resp$bodyFile <- filename
      resp$bodyFileOwned <- owned
    }
    resp
  }

  on_error <- function(e) {
    list(
      status=500L,
      headers=list(
        'Content-Type'='text/plain; charset=UTF-8'
      ),
      body=charToRaw(enc2utf8(
        paste("ERROR:", conditionMessage(e), collapse="\n")
      ))
    )
  }

  # First, run the compute function. If it errored, return error response.
  # Then check if it returned a promise. If so, promisify the next step.
  # If not, run the next step immediately.
  compute_error <- NULL
  response <- tryCatch(
    compute(),
    error = function(e) compute_error <<- e
  )
  if (!is.null(compute_error)) {
    return(on_error(compute_error))
  }

  if (is.promise(response)) {
    response %...>% prepare_response %...!% on_error
  } else {
    tryCatch(prepare_response(response), error = on_error)
  }
}

AppWrapper <- R6::R6Class(
  'AppWrapper',
  private = list(
    app = NULL,                    # List defining app
    wsconns = NULL,                # An environment containing websocket connections
    supportsOnHeaders = NULL       # Logical
  ),
  public = list(
    initialize = function(app) {
      if (is.function(app))
        private$app <- list(call=app)
      else
        private$app <- app

      # private$app$onHeaders can error (e.g. if private$app is a reference class)
      private$supportsOnHeaders <- isTRUE(try(!is.null(private$app$onHeaders), silent=TRUE))

      # staticPaths are saved in a field on this object, because they are read
      # from the app object only during initialization. This is the only time
      # it makes sense to read them from the app object, since they're
      # subsequently used on the background thread, and for performance
      # reasons it can't call back into R. Note that if the app object is a
      # reference object and app$staticPaths is changed later, it will have no
      # effect on the behavior of the application.
      #
      # If private$app is a reference class, accessing private$app$staticPaths
      # can error if not present.
      if (class(try(private$app$staticPaths, silent = TRUE)) == "try-error" ||
          is.null(private$app$staticPaths))
      {
        self$staticPaths <- list()
      } else {
        self$staticPaths <- normalizeStaticPaths(private$app$staticPaths)
      }

      if (class(try(private$app$staticPathOptions, silent = TRUE)) == "try-error" ||
          is.null(private$app$staticPathOptions))
      {
        # Use defaults
        self$staticPathOptions <- staticPathOptions()
      } else if (inherits(private$app$staticPathOptions, "staticPathOptions")) {
        self$staticPathOptions <- normalizeStaticPathOptions(private$app$staticPathOptions)
      } else {
        stop("staticPathOptions must be an object of class staticPathOptions.")
      }

      private$wsconns <- new.env(parent = emptyenv())
    },
    onHeaders = function(req) {
      if (!private$supportsOnHeaders)
        return(NULL)

      rookCall(private$app$onHeaders, req)
    },
    onBodyData = function(req, bytes) {
      if (is.null(req$.bodyData))
        req$.bodyData <- file(open='w+b', encoding='UTF-8')
      writeBin(bytes, req$.bodyData)
    },
    call = function(req, cpp_callback) {
      # The cpp_callback is an external pointer to a C++ function that writes
      # the response.

      resp <- if (is.null(private$app$call)) {
        list(
          status = 404L,
          headers = list(
            "Content-Type" = "text/plain"
          ),
          body = "404 Not Found\n"
        )
      } else {
        rookCall(private$app$call, req, req$.bodyData, seek(req$.bodyData))
      }
      # Note: rookCall() should never throw error because all the work is
      # wrapped in tryCatch().

      clean_up <- function() {
        if (!is.null(req$.bodyData)) {
          close(req$.bodyData)
        }
        req$.bodyData <- NULL
      }

      if (is.promise(resp)) {
        # Slower path if resp is a promise
        resp <- resp %...>% invokeCppCallback(., cpp_callback)
        finally(resp, clean_up)

      } else {
        # Fast path if resp is a regular value
        on.exit(clean_up())
        invokeCppCallback(resp, cpp_callback)
      }

      invisible()
    },

    staticPaths = NULL,            # List of static paths
    staticPathOptions = NULL       # StaticPathOptions object
  )
)

# Needed so that Rcpp registers the 'httpuv_decodeURIComponent' symbol
legacy_dummy <- function(value){
  .Call('httpuv_decodeURIComponent', PACKAGE = "httpuv", value)
}

#'
#' Class definitions and their `show` & `summary` methods.
#'
#'
#' To conveniently and safely pass messages between R and H2O, this package relies
#' on S4 objects to capture and pass state. This R file contains all of the h2o
#' package's classes as well as their complementary `show` methods. The end user
#' will typically never have to reason with these objects directly, as there are
#' S3 accessor methods provided for creating new objects.
#'
#' @name ClassesIntro
NULL

#-----------------------------------------------------------------------------------------------------------------------
# Class Defintions
#-----------------------------------------------------------------------------------------------------------------------

setClassUnion("data.frameOrNULL", c("data.frame", "NULL"))

#'
#' The H2OConnection class.
#'
#' This class represents a connection to the H2O Cloud.
#'
#' Because H2O is not a master-slave architecture, there is no restriction on which H2O node
#' is used to establish the connection between R (the client) and H2O (the server).
#'
#' A new H2O connection is established via the h2o.init() function, which takes as parameters
#' the `ip` and `port` of the machine running an instance to connect with. The default behavior
#' is to connect with a local instance of H2O at port 54321, or to boot a new local instance if one
#' is not found at port 54321.
#' @slot ip A \code{character} string specifying the IP address of the H2O server.
#' @slot port A \code{numeric} value specifying the port number of the H2O server.
#' @slot session_id A \code{numeric} string specifying the H2O session identifier.
#' @aliases H2OConnection
setClass("H2OConnection",
         representation(ip="character", port="numeric", session_id="character", envir="environment"),
         prototype(ip=NA_character_, port=NA_integer_, session_id=NA_character_, envir=new.env())
         )
setMethod("initialize", "H2OConnection",
function(.Object, ...) {
  .Object <- callNextMethod()
  assign("key_count", 0L, .Object@envir)
  .Object
})
setClassUnion("H2OConnectionOrNULL", c("H2OConnection", "NULL"))

#' @rdname H2OConnection-class
setMethod("show", "H2OConnection", function(object) {
  cat("IP Address:", object@ip,         "\n")
  cat("Port      :", object@port,       "\n")
  cat("Session ID:", object@session_id, "\n")
})

#'
#' The H2OObject class
#'
setClass("H2OObject",
         representation(conn="H2OConnectionOrNULL", key="character", finalizers="list"),
         prototype(conn=NULL, key=NA_character_, finalizers=list()),
         contains="VIRTUAL")

.keyFinalizer <- function(envir) {
  try(h2o.rm(get("key", envir), get("conn", envir)), silent=TRUE)
}

.newH2OObject <- function(Class, ..., conn = NULL, key = NA_character_, finalizers = list(), linkToGC = FALSE) {
  if (linkToGC && !is.na(key) && is(conn, "H2OConnection")) {
    envir <- new.env()
    assign("key", key, envir)
    assign("conn", conn, envir)
    reg.finalizer(envir, .keyFinalizer, onexit = FALSE)
    finalizers <- c(list(envir), finalizers)
  }
  new(Class, ..., conn = conn, key = key, finalizers = finalizers)
}

#'
#' The Node class.
#'
#' An object of type Node inherits from an H2OFrame, but holds no H2O-aware data. Every node in the abstract syntax tree
#' An object of type Node inherits from an H2OFrame, but holds no H2O-aware data. Every node in the abstract syntax tree
#' has as its ancestor this class.
#'
#' Every node in the abstract syntax tree will have a symbol table, which is a dictionary of types and names for
#' all the relevant variables and functions defined in the current scope. A missing symbol is therefore discovered
#' by looking up the tree to the nearest symbol table defining that symbol.
setClass("Node", contains="VIRTUAL")

#'
#' The ASTNode class.
#'
#' This class represents a node in the abstract syntax tree. An ASTNode has a root. The root has children that either
#' point to another ASTNode, or to a leaf node, which may be of type ASTNumeric or ASTFrame.
#' @slot root Object of type \code{Node}
#' @slot children Object of type \code{list}
setClass("ASTNode", representation(root="Node", children="list"), contains="Node")
setClassUnion("ASTNodeOrNULL", c("ASTNode", "NULL"))

#' @rdname ASTNode-class
setMethod("show", "ASTNode", function(object) cat(.visitor(object), "\n") )

#'
#' The ASTApply class.
#'
#' This class represents an operator between one or more H2O objects. ASTApply nodes are always root nodes in a tree and
#' are never leaf nodes. Operators are discussed more in depth in ops.R.
setClass("ASTApply", representation(op="character"), contains="Node")

setClass("ASTEmpty",  representation(key="character"), contains="Node")
setClass("ASTBody",   representation(statements="list"), contains="Node")
setClass("ASTFun",    representation(name="character", arguments="character", body="ASTBody"), contains="Node")
setClass("ASTSpan",   representation(root="Node",    children  = "list"), contains="Node")
setClass("ASTSeries", representation(op="character", children  = "list"), contains="Node", prototype(op="{"))
setClass("ASTIf",     representation(op="character", condition = "ASTNode",  body = "ASTBody"), contains="Node", prototype(op="if"))
setClass("ASTElse",   representation(op="character", body      = "ASTBody"), contains="Node", prototype(op="else"))
setClass("ASTFor",    representation(op="character", iterator  = "list",  body = "ASTBody"), contains="Node", prototype(op="for"))
setClass("ASTReturn", representation(op="character", children  = "ASTNode"), contains="Node", prototype(op="return"))

#'
#' The H2OFrame class
#'
setClass("H2OFrame",
         representation(ast="ASTNodeOrNULL", nrows="numeric", ncols="numeric", col_names="character",
                        factors="data.frameOrNULL"),
         prototype(conn       = NULL,
                   key        = NA_character_,
                   finalizers = list(),
                   ast        = NULL,
                   nrows      = NA_integer_,
                   ncols      = NA_integer_,
                   col_names  = NA_character_,
                   factors    = NULL),
         contains ="H2OObject")

setMethod("show", "H2OFrame", function(object) {
  nr <- nrow(object)
  nc <- ncol(object)
  cat(class(object), " with ",
      nr, ifelse(nr == 1L, " row and ", " rows and "),
      nc, ifelse(nc == 1L, " column\n", " columns\n"), sep = "")
  if (nr > 10L)
    cat("\nFirst 10 rows:\n")
  print(head(object, 10L))
  invisible(object)
})

#'
#' The H2ORawData class.
#'
#' This class represents data in a post-import format.
#'
#' Data ingestion is a two-step process in H2O. First, a given path to a data source is _imported_ for validation by the
#' user. The user may continue onto _parsing_ all of the data into memory, or the user may choose to back out and make
#' corrections. Imported data is in a staging area such that H2O is aware of the data, but the data is not yet in
#' memory.
#'
#' The H2ORawData is a representation of the imported, not yet parsed, data.
#' @slot conn An \code{H2OConnection} object containing the IP address and port number of the H2O server.
#' @slot key An object of class \code{"character"}, which is the hex key assigned to the imported data.
#' @aliases H2ORawData
setClass("H2ORawData", contains="H2OObject")

#' @rdname H2ORawData-class
setMethod("show", "H2ORawData", function(object) {
  print(object@conn)
  cat("Raw Data Key:", object@key, "\n")
})

# No show method for this type of object.

#'
#' The H2OW2V object.
#'
#' This class represents a h2o-word2vec object.
#'
setClass("H2OW2V", representation(train.data="H2OFrame"), contains="H2OObject")

#'
#' The H2OModel object.
#'
#' This virtual class represents a model built by H2O.
#'
#' This object has slots for the key, which is a character string that points to the model key existing in the H2O cloud,
#' the data used to build the model (an object of class H2OFrame).

#' @slot conn Object of class \code{H2OConnection}, which is the client object that was passed into the function call.
#' @slot key Object of class \code{character}, representing the unique hex key that identifies the model
#' @slot model Object of class \code{list} containing the characteristics of the model returned by the algorithm.
#' @aliases H2OModel
setClass("H2OModel",
         representation(algorithm="character", parameters="list", model="list"),
         contains=c("VIRTUAL", "H2OObject"))

setMethod("show", "H2OModel", function(object) {
  cat(class(object), ": ", object@algorithm, "\n\n", sep = "")
  cat("Model Details:\n")
  sub <- intersect(names(object@model), names(object@model$help))
  val <- object@model[sub]
  lab <- object@model$help[sub]
  lab <- lab[names(lab) != "help"]
  val <- val[names(lab)]
  mapply(function(val, lab) { cat("\n", lab, "\n"); print(val) }, val, lab)
  invisible(object)
})

setClass("H2OUnknownModel",     contains="H2OModel")
setClass("H2OBinomialModel",    contains="H2OModel")
setClass("H2OMultinomialModel", contains="H2OModel")
setClass("H2ORegressionModel",  contains="H2OModel")
setClass("H2OClusteringModel",  contains="H2OModel")

#' 
#' The H2OModelMetrics Object.
#'
#' A class for constructing performance measures of H2O models.
#'
setClass("H2OModelMetrics", 
         representation(algorithm="character", metrics="list"),
         contains="VIRTUAL")

setMethod("show", "H2OModelMetrics", function(object) {
  cat(class(object), ": ", object@algorithm, "\n\n", sep="")
})

setClass("H2OUnknownMetrics",     contains="H2OModelMetrics")
setClass("H2OBinomialMetrics",    contains="H2OModelMetrics")
setClass("H2OMultinomialMetrics", contains="H2OModelMetrics")
setClass("H2ORegressionMetrics",  contains="H2OModelMetrics")
setClass("H2OClusteringMetrics",  contains="H2OModelMetrics")

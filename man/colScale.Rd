% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/R-utils.R
\name{colScale}
\alias{colScale}
\title{Scale columns of a matrix}
\usage{
colScale(x, add_attr = TRUE)
}
\arguments{
\item{x}{A matrix.}

\item{add_attr}{If TRUE, the column means and standard deviations are returned as attributes. This is consistent with \code{\link[base:scale]{base::scale()}}.}
}
\value{
The scaled matrix.
}
\description{
Same as \code{base::scale()} but much faster.
}
\section{Reference}{

This function was adopted from John Muschelli's code on \href{https://hopstat.wordpress.com/2016/02/23/a-faster-scale-function/}{StackOverflow}, but I changed the underlying functions to calculate mean and standard deviation from \code{matrixStats} to \code{Rfast}, which is much faster.
}


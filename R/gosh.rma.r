gosh.rma <- function(x, subsets, progbar=TRUE, parallel="no", ncpus=1, cl=NULL, ...) {

   if (!inherits(x, "rma"))
      stop("Argument 'x' must be an object of class \"rma\".")

   if (inherits(x, "rma.glmm"))
      stop("Method not yet implemented for objects of class \"rma.glmm\". Sorry!")

   if (inherits(x, "rma.mv"))
      stop("Method not yet implemented for objects of class \"rma.mv\". Sorry!")

   na.act <- getOption("na.action")

   if (!is.element(na.act, c("na.omit", "na.exclude", "na.fail", "na.pass")))
      stop("Unknown 'na.action' specified under options().")

   if (x$k == 1)
      stop("Stopped because k = 1.")

   parallel <- match.arg(parallel, c("no", "snow", "multicore"))

   ### total number of possible subsets

   N.tot <- sum(choose(x$k, x$p:x$k))

   ### if 'subsets' is missing, include all possible subsets if N.tot is <= 10^6
   ### and otherwise include 10^6 random subsets; if the user specifies 'subsets'
   ### and N.tot is actually <= than what was specified, then again include all
   ### possible subsets

   if (missing(subsets)) {
      if (N.tot <= 10^6) {
         exact <- TRUE
      } else {
         exact <- FALSE
         N.tot <- 10^6
      }
   } else {
      if (N.tot <= subsets) {
         exact <- TRUE
      } else {
         exact <- FALSE
         N.tot <- subsets
      }
   }

   if (N.tot == Inf)
      stop("Too many iterations required for all combinations.\n")

   if (progbar)
      cat("Fitting ", N.tot, " models (based on ", ifelse(exact, "all possible", "random"), " subsets).\n", sep="")

   #########################################################################

   ### generate inclusion matrix (either exact or at random)

   if (exact) {

      incl <- as.matrix(expand.grid(replicate(x$k, list(c(FALSE,TRUE))), KEEP.OUT.ATTRS=FALSE))
      incl <- incl[apply(incl, 1, sum) >= x$p,]

      ### slower, but does not generate rows that need to be filtered out (as above)
      #incl <- lapply(x$p:x$k, function(m) apply(combn(x$k,m), 2, function(l) 1:x$k %in% l))
      #incl <- t(do.call(cbind, incl))

   } else {

      j <- sample(x$p:x$k, N.tot, replace=TRUE, prob=dbinom(x$p:x$k, x$k, .5))
      incl <- t(sapply(j, function(m) 1:x$k %in% sample(x$k, m)))

   }

   colnames(incl) <- 1:x$k

   ### check if model is a standard FE model (fitted with the usual 1/vi weights)

   if (x$method=="FE" && x$weighted && is.null(x$weights) && x$int.only) {
      FE <- TRUE
   } else {
      FE <- FALSE
   }

   #########################################################################

   if (parallel=="no") {

      ### set up vectors to store results in

      b <- try(matrix(NA_real_, nrow=N.tot, ncol=x$p), silent=TRUE)

      if (inherits(b, "try-error"))
         stop("Number of models requested too large.")

      het <- try(matrix(NA_real_, nrow=N.tot, ncol=5), silent=TRUE)

      if (inherits(het, "try-error"))
         stop("Number of models requested too large.")

      if (progbar)
         pbar <- txtProgressBar(min=0, max=N.tot, style=3)

      for (j in 1:N.tot) {

         if (progbar)
            setTxtProgressBar(pbar, j)

         if (inherits(x, "rma.uni")) {
            if (FE) {
               res <- .profile.rma.uni(val=1, obj=x, subset=TRUE, sel=incl[j,], FE=TRUE)
            } else {
               res <- try(suppressWarnings(rma.uni(x$yi, x$vi, weights=x$weights, mods=x$X, method=x$method, weighted=x$weighted, intercept=FALSE, knha=x$knha, control=x$control, subset=incl[j,])), silent=TRUE)
            }
         }

         if (inherits(x, "rma.mh")) {
            if (is.element(x$measure, c("RR","OR","RD"))) {
               res <- try(suppressWarnings(rma.mh(ai=x$ai, bi=x$bi, ci=x$ci, di=x$di, measure=x$measure, add=x$add, to=x$to, drop00=x$drop00, correct=x$correct, subset=incl[j,])), silent=TRUE)
            } else {
               res <- try(suppressWarnings(rma.mh(x1i=x$x1i, x2i=x$x2i, t1i=x$t1i, t2i=x$t2i, measure=x$measure, add=x$add, to=x$to, drop00=x$drop00, correct=x$correct, subset=incl[j,])), silent=TRUE)
            }
         }

         if (inherits(x, "rma.peto"))
            res <- try(suppressWarnings(rma.peto(ai=x$ai, bi=x$bi, ci=x$ci, di=x$di, add=x$add, to=x$to, drop00=x$drop00, subset=incl[j,])), silent=TRUE)

         if (inherits(res, "try-error"))
            next

         ### removing an observation could lead to a model coefficient becoming inestimable (for 'rma.uni' objects)

         if (any(res$coef.na))
            next

         b[j,] <- c(res$b)

         het[j,1] <- res$k
         het[j,2] <- res$QE
         het[j,3] <- res$I2
         het[j,4] <- res$H2
         het[j,5] <- res$tau2

      }

      if (progbar)
         close(pbar)

   }

   if (parallel=="snow" || parallel == "multicore") {

      if (!requireNamespace("parallel", quietly=TRUE))
         stop("Please install the 'parallel' package for parallel processing.")

      ncpus <- as.integer(ncpus)

      if (ncpus < 1)
         stop("Argument 'ncpus' must be >= 1.")

      if (parallel == "multicore") {

         if (inherits(x, "rma.uni"))
            res <- parallel::mclapply(1:N.tot, .profile.rma.uni, obj=x, mc.cores=ncpus, parallel=parallel, subset=TRUE, sel=incl, FE=FE)

         if (inherits(x, "rma.mh"))
            res <- parallel::mclapply(1:N.tot, .profile.rma.mh, obj=x, mc.cores=ncpus, parallel=parallel, subset=TRUE, sel=incl)

         if (inherits(x, "rma.peto"))
            res <- parallel::mclapply(1:N.tot, .profile.rma.peto, obj=x, mc.cores=ncpus, parallel=parallel, subset=TRUE, sel=incl)

      }

      if (parallel == "snow") {

         if (is.null(cl)) {
            cl <- parallel::makePSOCKcluster(ncpus)
            clnew <- TRUE
         } else {
            clnew <- FALSE
         }

         if (inherits(x, "rma.uni"))
            res <- parallel::parLapply(cl, 1:N.tot, .profile.rma.uni, obj=x, parallel=parallel, subset=TRUE, sel=incl, FE=FE)

         if (inherits(x, "rma.mh"))
            res <- parallel::parLapply(cl, 1:N.tot, .profile.rma.mh, obj=x, parallel=parallel, subset=TRUE, sel=incl)

         if (inherits(x, "rma.peto"))
            res <- parallel::parLapply(cl, 1:N.tot, .profile.rma.peto, obj=x, parallel=parallel, subset=TRUE, sel=incl)

         if (clnew)
            parallel::stopCluster(cl)

      }

      b <- do.call("rbind", lapply(res, function(z) t(z$b)))
      het <- do.call("rbind", lapply(res, function(z) z$het))

   }

   #########################################################################

   ### in case a model fit was skipped, this guarantees that we still
   ### get a value for k in the first column for each model

   het[,1] <- apply(incl, 1, sum)

   ### set column names

   colnames(het) <- c("k", "QE", "I2", "H2", "tau2")

   if (x$int.only) {
      colnames(b) <- "estimate"
   } else {
      colnames(b) <- colnames(x$X)
   }

   ### combine het and b objects and order incl and res by k

   res <- data.frame(het, b)
   incl <- incl[order(res$k),]
   res <- res[order(res$k),]

   ### fix rownames

   rownames(res) <- 1:nrow(res)
   rownames(incl) <- 1:nrow(incl)

   out <- list(res=res, incl=incl, k=x$k, int.only=x$int.only, method=x$method, measure=x$measure)

   class(out) <- "gosh.rma"
   return(out)

}

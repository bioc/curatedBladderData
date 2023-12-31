#!/usr/bin/env Rscript

#R --vanilla "--args ../input/patientselection_bladder.config bladder.eset.rda
# tmp.log"  < createEsetList.R 

inputArgs <- commandArgs(TRUE)

library(genefilter)
library(survival)
library(logging)


if (length(inputArgs) >=3) {
    kConfigFile <- inputArgs[1]
    source(kConfigFile)
    kOutputFile <- inputArgs[2]
    kLogFile <- inputArgs[3]
} else {
    # assume data was sourced and config options were set
    kLogFile <-"createEsetList.log"
}

##Logging setup
basicConfig()
addHandler(writeToFile, logger="", file=kLogFile)

loginfo("Inside script createEsetList.R - inputArgs =")
if (length(inputArgs)) loginfo(inputArgs)

if (!exists("package.name")) package.name <- "curatedOvarianData"

library(package.name, character.only=TRUE)

loginfo(paste("Loading", package.name,
sessionInfo()$otherPkgs[[package.name]]$Version))
##needed functions
filterQuantile <- function(object, q){
    if (!identical(q >=0 && q < 1, TRUE))
        stop("require 0 <= q < 1")
    if (!identical(class(object) == "ExpressionSet", TRUE))
        stop("object must be an ExpressionSet")
    gene.sd <- esApply(object,1,sd, na.rm=TRUE)
    gene.quantile <- quantile(gene.sd, probs=q)
    actual.makescutoff <- sum(gene.sd < gene.quantile) / length(gene.sd)
    ##make sure the correct number of genes are getting filtered:
    if (abs(q - actual.makescutoff) > 0.01){
        stop("Not scaling this object, likely pre-scaled.")
    }else{
        object <- object[gene.sd > gene.quantile, ]
    }
    return(object)
}
##recursive intersect function
intersectMany <- function(lst){
    ## Find the intersection of multiple vectors stored as elements of a
    ## list, through a tail-recursive function.
    if (length(lst)==2){
        return(intersect(lst[[1]],lst[[2]]))
    }else{
        return(intersectMany(c(list(intersect(lst[[1]],lst[[2]])),lst[-1:-2])))
    }
}

##load the esets
data(list=data(package=package.name)[[3]][,3])

strEsets <- ls(pattern="^.*_eset$")

esets <- list()
loginfo("Clean up the esets.")
for (strEset in ls(pattern="_eset$")){
    eset <- get(strEset)
    ##Deal with genes which had a single probe mapping to multiple genes
    if (exists("probes.not.mapped.uniquely") && identical(probes.not.mapped.uniquely, "drop"))  ##Drop rows without unique gene name
        eset <- eset[!grepl("///",featureNames(eset),fixed=TRUE),]
    ##samples to be removed
    remove <- rep(FALSE, ncol(eset))
    ##remove samples without required metadata
    if(length(meta.required) > 0){
        for (varname in meta.required){
            if (varname %in% colnames(pData(eset))){
                remove[ is.na(eset[[varname]]) ] <- TRUE
            }
        }
    }
    ##remove samples not matching regexes
    all.rules <- ls(pattern="rule\\.[0-9]+")
    for (one.rule in all.rules){
        this.remove <- !grepl(get(one.rule)[2], eset[[ get(one.rule)[1] ]])
        if(!strict.checking)
            this.remove[ is.na(eset[[ get(one.rule)[1] ]]) ] <- FALSE
        remove[this.remove] <- TRUE
    }
    ##do the actual removal
    eset <- eset[, !remove]
    if (exists("considered.datasets") && !(strEset %in% considered.datasets))
    {
        loginfo(paste("excluding",strEset,
            "(considered.datasets)"))
        next
    }
    ##include study if it has enough samples and events:
    if(!exists("min.sample.size"))
        min.sample.size <- 1
    if ((exists("min.number.of.events") && min.number.of.events > 0 && sum(eset$vital_status == "deceased") < min.number.of.events) || (ncol(eset) < min.sample.size)){
        loginfo(paste("excluding", strEset, "(min.number.of.events or min.sample.size)"))
        next
    }
    if (exists("min.number.of.genes") && nrow(eset) < min.number.of.genes) {
        loginfo(paste("excluding",strEset,"(min.number.of.genes)"))
        next
    }
    if (exists("remove.retracted") && remove.retracted && length(grep("retracted", experimentData(eset)@other$warnings$warnings)) > 0){
        loginfo(paste("excluding",strEset,"(remove.retracted)"))
        next
    }
    if (exists("remove.subsets") && remove.subsets && length(grep("subset", experimentData(eset)@other$warnings$warnings)) > 0){
        loginfo(paste("excluding",strEset,"(remove.subsets)"))
        next
    }
    ##filter genes with standard deviation below the required quantile
    if(quantile.cutoff > 0 && quantile.cutoff < 1){
        eset <- filterQuantile(eset, q=quantile.cutoff)
    }
    ##rescale to z-scores
    if(rescale){
        exprs(eset) <- t(scale(t(exprs(eset))))
    }
    loginfo(paste("including",strEset))
    featureNames(eset) <- make.names(featureNames(eset))
    esets[[strEset]] <- eset
    rm(eset)
}

##optionally take the intersection of genes common to all platforms:
if(keep.common.only){
    features.per.dataset <- lapply(esets, featureNames)
    intersect.genes <- intersectMany(features.per.dataset)
    esets <- lapply(esets, function(eset){
        eset <- eset[intersect.genes, ]
        return(eset)
    })
}

ids.with.missing.data <- which(sapply(esets, function(X)
sum(!complete.cases(exprs(X))) > 0))
loginfo(paste("Ids with missing data:", paste(names(ids.with.missing.data),
collapse=", ")))

if (length(ids.with.missing.data) > 0 && exists("impute.missing") && impute.missing) {
    for (i in ids.with.missing.data) {
        require(impute)
        exprs(esets[[i]]) = impute.knn(exprs(esets[[i]]))$data
    }
} 

if (exists("add.surv.y") && is.function(add.surv.y)) {
    for (i in 1:length(esets)) {
        esets[[i]]$y = add.surv.y(esets[[i]])
    }
} 

if (exists("kOutputFile"))
    save(esets,file=kOutputFile)

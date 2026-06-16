#!/usr/bin/env Rscript
# =============================================================================
# sylph_phylo_distances.R
#
# All credits go to Claude
#
# Usage:
#   Rscript sylph_phylo_distances.R \
#     --sylph  path/to/profile.tsv \
#     --tree   path/to/gtdb.tree \
#     --out    output_prefix          \
#     [--min_cov 0]                   \
#     [--min_ani 0]                   \
#     [--format newick|nexus]
#
# Outputs (written to <out>_*):
#   <out>_pruned.nwk          – Newick tree containing only identified taxa
#   <out>_dist_matrix.tsv     – Pairwise phylogenetic distance matrix (N x N)
#   <out>_dist_long.tsv       – Long-format distances (taxon_A, taxon_B, distance)
#   <out>_summary.txt         – Run summary / QC log
#
# Accession matching:
#   Genome_file paths like:
#     gtdb_genomes_reps_r232/database/GCA/000/433/355/GCA_000433355.1_genomic.fna.gz
#   yield accession: GCA_000433355.1
#
#   GTDB tree tips are expected to look like:
#     GB_GCA_000433355.1   or   RS_GCF_000020605.1
#   The GB_/RS_ prefix is stripped for matching.
# =============================================================================

suppressPackageStartupMessages({
  library(ape)
  library(optparse)
  library(dplyr)
  library(tidyr)
  library(readr)
  library(stringr)
  library(purrr)
})

# ── 1. CLI argument parsing ───────────────────────────────────────────────────
option_list <- list(
  make_option(c("-s", "--sylph"),
              type    = "character",
              help    = "Path to sylph profile TSV file [required]"),
  make_option(c("-t", "--tree"),
              type    = "character",
              help    = "Path to GTDB reference tree (Newick or Nexus) [required]"),
  make_option(c("-o", "--out"),
              type    = "character",
              default = "sylph_phylo",
              help    = "Output file prefix [default: sylph_phylo]"),
  make_option(c("--min_cov"),
              type    = "double",
              default = 0.0,
              help    = "Minimum Eff_cov to retain a hit (default: 0, keep all)"),
  make_option(c("--min_ani"),
              type    = "double",
              default = 0.0,
              help    = "Minimum Adjusted_ANI to retain a hit (default: 0, keep all)"),
  make_option(c("--format"),
              type    = "character",
              default = "newick",
              help    = "Tree format: newick or nexus [default: newick]"),
  make_option(c("--verbose"),
              action  = "store_true",
              default = FALSE,
              help    = "Print extra diagnostic messages")
)

opt <- parse_args(OptionParser(option_list = option_list))

if (is.null(opt$sylph) || is.null(opt$tree)) {
  stop("--sylph and --tree are required. Run with --help for usage.")
}

log_msg <- function(...) {
  cat(sprintf("[%s] %s\n", format(Sys.time(), "%H:%M:%S"), paste0(...)))
}
verbose_msg <- function(...) {
  if (isTRUE(opt$verbose)) log_msg(...)
}

# ── 2. Load sylph profile ─────────────────────────────────────────────────────
log_msg("Reading sylph profile: ", opt$sylph)

sylph_raw <- tryCatch(
  read_tsv(opt$sylph, show_col_types = FALSE),
  error = function(e) stop("Cannot read sylph TSV: ", e$message)
)

log_msg(sprintf("Sylph profile: %d rows, %d columns", nrow(sylph_raw), ncol(sylph_raw)))
verbose_msg("Columns: ", paste(names(sylph_raw), collapse = ", "))

# ── 2a. Identify required columns ─────────────────────────────────────────────
# Genome_file: full path to genome fasta
# Eff_cov / Adjusted_ANI: quality filters

find_col <- function(df, candidates, role, required = TRUE) {
  found <- intersect(candidates, names(df))
  if (length(found) == 0) {
    if (required) stop(sprintf(
      "Cannot find '%s' column. Tried: %s\nActual columns: %s",
      role, paste(candidates, collapse=", "), paste(names(df), collapse=", ")))
    return(NA_character_)
  }
  found[1]
}

genome_col <- find_col(sylph_raw, c("Genome_file", "genome_file", "Genome"),    "Genome_file")
cov_col    <- find_col(sylph_raw, c("Eff_cov", "Mean_cov_geq1", "Median_cov",
                                     "coverage", "Coverage"),                     "coverage")
ani_col    <- find_col(sylph_raw, c("Adjusted_ANI", "Naive_ANI", "ANI", "ani"), "ANI")

log_msg(sprintf("Using columns: genome='%s'  cov='%s'  ANI='%s'",
                genome_col, cov_col, ani_col))

# ── 2b. Filter hits ───────────────────────────────────────────────────────────
sylph_filt <- sylph_raw %>%
  filter(!is.na(.data[[genome_col]])) %>%
  filter(as.numeric(.data[[cov_col]])  >= opt$min_cov) %>%
  filter(as.numeric(.data[[ani_col]])  >= opt$min_ani)

log_msg(sprintf("Retained %d / %d hits (min_cov=%.3f, min_ani=%.3f)",
                nrow(sylph_filt), nrow(sylph_raw), opt$min_cov, opt$min_ani))

if (nrow(sylph_filt) == 0) stop("No hits passed the filters. Exiting.")

# ── 2c. Extract accessions from Genome_file paths ────────────────────────────
# Path format: .../GCA/000/433/355/GCA_000433355.1_genomic.fna.gz
# We want:      GCA_000433355.1
#
# Strategy: take the basename, then remove trailing _genomic.fna.gz (and variants)

extract_accession <- function(path) {
  basename(path) %>%
    str_remove("_genomic\\.(fna|fa|fasta)(\\.gz)?$") %>%
    str_remove("\\.(fna|fa|fasta)(\\.gz)?$")
}

sylph_filt <- sylph_filt %>%
  mutate(accession = extract_accession(.data[[genome_col]]))

n_unique <- n_distinct(sylph_filt$accession)
log_msg(sprintf("Unique accessions identified: %d", n_unique))
verbose_msg("First 10 accessions: ",
            paste(head(unique(sylph_filt$accession), 10), collapse = ", "))

# ── 3. Load GTDB tree ─────────────────────────────────────────────────────────
log_msg("Reading GTDB tree: ", opt$tree)

read_fn    <- if (tolower(opt$format) == "nexus") read.nexus else read.tree
gtdb_tree  <- tryCatch(read_fn(opt$tree),
                       error = function(e) stop("Cannot read tree: ", e$message))

if (inherits(gtdb_tree, "multiPhylo")) {
  log_msg("Multi-tree detected; using first tree.")
  gtdb_tree <- gtdb_tree[[1]]
}

log_msg(sprintf("Tree loaded: %d tips", Ntip(gtdb_tree)))
verbose_msg("Example tip labels: ",
            paste(head(gtdb_tree$tip.label, 5), collapse = " | "))

# ── 3a. Build a fast accession-to-tip-label lookup ───────────────────────────
# GTDB tip labels:  GB_GCA_000433355.1  or  RS_GCF_000020605.1
# After stripping the two-letter prefix + underscore we get the bare accession.

tree_tips        <- gtdb_tree$tip.label
tip_bare         <- str_remove(tree_tips, "^[A-Z]{2}_")   # GCA_000433355.1
bare_to_tip      <- setNames(tree_tips, tip_bare)          # named vector for O(1) lookup

# Matching function: tries exact tip match first, then bare match
match_to_tip <- function(acc) {
  # 1. Exact (e.g. tree uses bare accessions without prefix)
  if (acc %in% tree_tips)      return(acc)
  # 2. Bare lookup (most common: acc = "GCA_000433355.1", key in bare_to_tip)
  if (acc %in% names(bare_to_tip)) return(bare_to_tip[[acc]])
  # 3. Sylph acc might itself have GB_/RS_ prefix; strip and retry
  acc_bare <- str_remove(acc, "^[A-Z]{2}_")
  if (acc_bare %in% names(bare_to_tip)) return(bare_to_tip[[acc_bare]])
  # 4. Partial: tip label contains the accession string (slow fallback)
  hits <- tree_tips[str_detect(fixed(tree_tips), acc_bare)]
  if (length(hits) == 1)  return(hits)
  if (length(hits)  > 1) {
    verbose_msg("Ambiguous match for '", acc, "' → using first: ", hits[1])
    return(hits[1])
  }
  return(NA_character_)
}

# Apply matching (deduplicate first to speed things up)
unique_acc <- unique(sylph_filt$accession)
acc_map    <- tibble(
  accession = unique_acc,
  tree_label = map_chr(unique_acc, match_to_tip)
)

sylph_filt <- sylph_filt %>% left_join(acc_map, by = "accession")

matched   <- sylph_filt %>% filter(!is.na(tree_label))
unmatched <- sylph_filt %>% filter( is.na(tree_label))

log_msg(sprintf("Matched %d / %d unique accessions to tree tips.",
                n_distinct(matched$accession),
                n_distinct(sylph_filt$accession)))

if (nrow(unmatched) > 0) {
  log_msg(sprintf("WARNING: %d hits could not be matched (see summary file).",
                  nrow(unmatched)))
}

tips_to_keep <- unique(matched$tree_label)

if (length(tips_to_keep) < 2) {
  stop(sprintf(
    "Only %d tip(s) could be matched to the tree. ≥2 needed for distance calculation.",
    length(tips_to_keep)
  ))
}

# ── 4. Prune tree ─────────────────────────────────────────────────────────────
log_msg(sprintf("Pruning tree to %d matched tips...", length(tips_to_keep)))
tips_to_drop <- setdiff(tree_tips, tips_to_keep)
pruned_tree  <- drop.tip(gtdb_tree, tips_to_drop)
log_msg(sprintf("Pruned tree: %d tips.", Ntip(pruned_tree)))

# ── 5a. Pairwise phylogenetic distances ───────────────────────────────────────
log_msg("Computing pairwise phylogenetic distances (cophenetic)...")
dist_matrix <- cophenetic.phylo(pruned_tree)
dist_matrix <- dist_matrix[sort(rownames(dist_matrix)), sort(colnames(dist_matrix))]

# ── 5b. Faith's phylogenetic diversity ───────────────────────────────────────
faith_pd <- sum(pruned_tree$edge.length, na.rm = TRUE)
log_msg(sprintf("Faith's PD = %.6f", faith_pd))

# ── 6. Build per-tip metadata table (for annotation) ─────────────────────────
# Keep one row per matched tip (highest-coverage hit wins if duplicates exist)
tip_meta <- matched %>%
  group_by(tree_label) %>%
  slice_max(order_by = as.numeric(.data[[cov_col]]), n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  select(tree_label, accession,
         genome_file  = all_of(genome_col),
         eff_cov      = all_of(cov_col),
         adjusted_ani = all_of(ani_col),
         any_of(c("Taxonomic_abundance", "Sequence_abundance",
                   "Taxonomic_label",   "Contig_name")))

# ── 7. Write outputs ──────────────────────────────────────────────────────────
out_prefix <- opt$out

# 7a. Pruned tree
out_tree <- paste0(out_prefix, "_pruned.nwk")
write.tree(pruned_tree, file = out_tree)
log_msg("Pruned tree → ", out_tree)

# 7b. Distance matrix (wide)
out_matrix <- paste0(out_prefix, "_dist_matrix.tsv")
dist_df    <- as.data.frame(dist_matrix)
dist_df    <- cbind(taxon = rownames(dist_df), dist_df)
write_tsv(dist_df, out_matrix)
log_msg("Distance matrix → ", out_matrix)

# 7c. Long-format distances (upper triangle, no self)
out_long  <- paste0(out_prefix, "_dist_long.tsv")
dist_long <- as.data.frame(as.table(dist_matrix)) %>%
  rename(taxon_A = Var1, taxon_B = Var2, phylo_distance = Freq) %>%
  filter(as.character(taxon_A) < as.character(taxon_B)) %>%
  arrange(phylo_distance)

# Annotate with accession + coverage for each partner
meta_a <- tip_meta %>% select(tree_label, accession_A = accession,
                               eff_cov_A = eff_cov, adj_ani_A = adjusted_ani)
meta_b <- tip_meta %>% select(tree_label, accession_B = accession,
                               eff_cov_B = eff_cov, adj_ani_B = adjusted_ani)

dist_long <- dist_long %>%
  left_join(meta_a, by = c("taxon_A" = "tree_label")) %>%
  left_join(meta_b, by = c("taxon_B" = "tree_label"))

write_tsv(dist_long, out_long)
log_msg(sprintf("Long-format distances → %s  (%d pairs)", out_long, nrow(dist_long)))

# 7d. Tip metadata
out_meta <- paste0(out_prefix, "_tip_metadata.tsv")
write_tsv(tip_meta, out_meta)
log_msg("Tip metadata → ", out_meta)

# 7e. Summary
out_summary <- paste0(out_prefix, "_summary.txt")
sink(out_summary)
cat("=== sylph_phylo_distances.R — Run Summary ===\n\n")
cat(sprintf("Date/time       : %s\n", Sys.time()))
cat(sprintf("Sylph profile   : %s\n", opt$sylph))
cat(sprintf("GTDB tree       : %s\n", opt$tree))
cat(sprintf("Output prefix   : %s\n", out_prefix))
cat(sprintf("Min Eff_cov     : %.3f\n", opt$min_cov))
cat(sprintf("Min ANI         : %.3f\n", opt$min_ani))

cat("\n--- Filtering ---\n")
cat(sprintf("Total sylph rows         : %d\n", nrow(sylph_raw)))
cat(sprintf("After cov/ANI filter     : %d\n", nrow(sylph_filt)))
cat(sprintf("Unique accessions        : %d\n", n_unique))
cat(sprintf("Matched to tree          : %d\n", n_distinct(matched$accession)))
cat(sprintf("Unmatched (dropped)      : %d\n", n_distinct(unmatched$accession)))

if (nrow(unmatched) > 0) {
  cat("\nUnmatched accessions:\n")
  walk(unique(unmatched$accession), ~ cat(sprintf("  %s\n", .x)))
}

cat("\n--- Tree ---\n")
cat(sprintf("Original tips            : %d\n", Ntip(gtdb_tree)))
cat(sprintf("Pruned tips              : %d\n", Ntip(pruned_tree)))

cat("\n--- Distance Summary ---\n")
cat(sprintf("Pairwise comparisons     : %d\n", nrow(dist_long)))
cat(sprintf("Min distance             : %.6f\n", min(dist_long$phylo_distance)))
cat(sprintf("Max distance             : %.6f\n", max(dist_long$phylo_distance)))
cat(sprintf("Mean distance            : %.6f\n", mean(dist_long$phylo_distance)))
cat(sprintf("Median distance          : %.6f\n", median(dist_long$phylo_distance)))
cat(sprintf("Faith's PD               : %.6f\n", faith_pd))

cat("\n--- Matched taxa (tree label  |  accession  |  Eff_cov  |  ANI) ---\n")
tip_meta %>%
  arrange(desc(as.numeric(eff_cov))) %>%
  mutate(line = sprintf("  %-35s  %-25s  cov=%-8.3f  ANI=%.2f",
                        tree_label, accession,
                        as.numeric(eff_cov), as.numeric(adjusted_ani))) %>%
  pull(line) %>%
  walk(cat, "\n")

cat("\n--- 10 closest pairs ---\n")
print(head(dist_long %>% select(taxon_A, taxon_B, phylo_distance,
                                accession_A, accession_B), 10),
      row.names = FALSE)
sink()
log_msg("Summary → ", out_summary)

log_msg("Done.")

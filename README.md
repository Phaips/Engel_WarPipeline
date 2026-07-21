# [Engel lab](https://www.cellarchlab.com/) Warp Pipeline

A compact workflow connecting [Warp/M](https://github.com/warpem/warp), [Miss-Alignment](https://github.com/warpem/miss-alignment), [pytom-match-pick](https://github.com/SBC-Utrecht/pytom-match-pick), and [IsoNet2](https://github.com/IsoNet-cryoET/IsoNet).

## Pipeline overview

1. **`submit_warp.sh`** processes raw tilt-series data in Warp, performs initial IMOD or AreTomo alignment, runs Miss-Alignment, and reconstructs the final tomograms in `warp_tiltseries_<RUN_NAME>/reconstruction_miss/`.
2. **`warp2pytom.py`** generates and submits pytom-match-pick jobs from the Warp XML metadata in batch!
3. **`submit_export_particles.sh`** merges pytom particle STAR files, normalizes their tomogram identifiers for WarpTools, exports particles, and merges the resulting metadata across datasets for [RELION5](https://github.com/3dem/relion/tree/ver5.0).
4. **`submit_isonet2.sh`** trains and applies IsoNet2 using the post-Miss-Alignment odd/even half tomograms, tilt angles, Warp XML defocus values, and user-supplied masks.

## `submit_warp.sh`: Warp/M and Miss-Alignment

Edit the header block and submit with:

```bash
sbatch submit_warp.sh
```


# Batch Submission of `pytom-match-pick` from WarpM

This script automates batch submission of pytom-match-pick jobs on an HPC cluster (SLURM) by reading metadata directly from Warp tilt-series XMLs. It:

- Extracts **tilt angles** from `<Angles>` in each `Position_*.xml` (sign-flipped to the pytom convention)
- Reads **per-tilt defocus** (μm) from the `<GridCTF>`
- Builds **per-tilt exposure** from `<Dose>`
- Locates the matching reconstruction in `reconstruction/` 

and generates SLURM submission scripts and will run on all tilt-series matched by `--pattern` (default `Position*.xml`) unless restricted with `--include` / `--exclude`.

`--dry-run` generates the bash scripts without submitting them, allowing for quick sanity checks or manual execution.

Two submission modes are available:

- **`array`** (default): a single SLURM **array job** (`submit_array.sh`) over all tomograms
- **`per-tomo`**: one standalone `submit_<prefix>.sh` per tomogram


## Usage

```bash
./warp2pytom.py \
  -i /path/to/warp/tiltseries \  # required: dir with Position_*.xml and reconstruction/
  -d submission \                # optional: output dir name (gets created) default submission
  -t /path/to/template.mrc \     # required
  -m /path/to/mask.mrc \         # required
  -g 0 \                         # required, GPU IDs space separated numbers no comma
  --voxel-size-angstrom 10 \   # required
  --dose 2 \                     # optional fallback if XML has no <Dose> (e-/Å² per tilt)
  --mode array \                 # array (default) or per-tomo
  [--include Position_*] [--exclude Position_5] \    # optional wildcard filtering
  [--angular-search 10 | --particle-diameter 140] \  # one of these is required
  -s 2 2 1 \                     # optional
  --per-tilt-weighting \         # optional but highly recommended
  --non-spherical-mask \         # optional
  --tomogram-ctf-model phase-flip \ # optional but recommended
  -r \                           # optional but recommended
  --rng-seed 69 \                # default: 69
  [--dry-run]                    # optional
```

Written by default:
`--amplitude-contrast 0.07
--spherical-aberration 2.7
--voltage 300`

> One of `--particle-diameter` or `--angular-search` is **required** (mutually exclusive).



## `submit_export_particles.sh`: Warp particle export

Set one entry per dataset in `DATASET_TAGS`, `PYTOM_DIRS`, and `WARP_SETTINGS`. Each PyTom directory is expected to contain particle STAR files under `<PYTOM_DIR>/*/*.star`, as produced after candidate extraction from the default `warp2pytom.py` submission structure.

- `EXPORT_DIM="2d"` exports per-tilt particle series and writes merged RELION5 `--tomo` particle, tomogram, and optimisation-set STAR files.
- `EXPORT_DIM="3d"` exports subtomograms and writes one merged conventional RELION particle STAR file.

The input STAR files must contain `rlnCoordinateX/Y/Z`, `rlnMicrographName`. `COORDS_ANGPIX` is the coordinate pixel size; `OUTPUT_ANGPIX` is the requested particle pixel size; `DIAMETER_ANGSTROM` is in Å.

```bash
sbatch submit_export_particles.sh
```

The merge step requires Python with `pandas` and `starfile`, normally available in the pytom-match-pick environment.

## `submit_isonet2.sh`: IsoNet2 denoising

Edit the paths to the Warp tilt-series folder, corresponding tomostar folder, and mask folder, then submit:

```bash
sbatch submit_isonet2.sh
```

The script reads odd/even half tomograms from `reconstruction_miss/`, determines the dataset-wide tilt range from the available `.tlt` files, reads the global defocus from each Warp XML and converts it from µm to Å, then runs IsoNet2 `prepare_star`, `refine`, and `predict`. Masks should be named `<prefix>.mrc` or `<prefix>_Vol_bmask.mrc`.


## License

MIT

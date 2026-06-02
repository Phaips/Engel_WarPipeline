# Batch Submission of `pytom-match-pick` from WarpM

This script automates batch submission of [pytom-match-pick](https://github.com/SBC-Utrecht/pytom-match-pick) jobs on an HPC cluster (SLURM) by reading metadata directly from **[Warp](https://github.com/warpem/warp)** tilt-series XMLs. It:

- Extracts **tilt angles** from `<Angles>` in each `Position_*.xml` (sign-flipped to the pytom convention)
- Reads **per-tilt defocus** (μm) from the `<GridCTF>`
- Builds **per-tilt exposure** from `<Dose>`
- Locates the matching reconstruction in `reconstruction/` 

and generates SLURM submission scripts and will run on all tilt-series matched by `--pattern` (default `Position*.xml`) unless restricted with `--include` / `--exclude`.

`--dry-run` generates the bash scripts without submitting them, allowing for quick sanity checks or manual execution.

Two submission modes are available:

- **`array`** (default): a single SLURM **array job** (`submit_array.sh`) over all tomograms
- **`per-tomo`**: one standalone `submit_<prefix>.sh` per tomogram

---

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

## Flag Summary

### Core flags
| Flag                          | Description                                          | Default        |
|-------------------------------|------------------------------------------------------|----------------|
| `-i, --warp-dir`              | Warp dir with `Position_*.xml` and `reconstruction/` | —              |
| `-t, --template`              | Template MRC for matching                            | —              |
| `-m, --mask`                  | Mask MRC for matching                                | —              |
| `-g, --gpu-ids`               | GPU IDs (e.g. `0` or `0 1`)                          | —              |
| `--voxel-size-angstrom`       | Voxel size in Å                                      | —              |
| `--particle-diameter`         | Particle diameter in Å (Crowther sampling)           | one of these   |
| `--angular-search`            | Angular search (float max or `.txt`)                 | is required    |
| `-d, --output-dir`            | Top-level folder for outputs                         | `submission`   |
| `--mode`                      | `array` (one array job) or `per-tomo`                | `array`        |
| `--pattern`                   | XML glob inside `--warp-dir`                          | `Position*.xml`|
| `--dose`                      | Fallback per-tilt dose (e‑/Å²) if XML has no `<Dose>`| none           |
| `--include` / `--exclude`     | Wildcard patterns for prefix filtering               | all / none     |
| `--dry-run`                   | Generate scripts without submitting                  | off            |

### Matching / input options
| Flag                           | Description                                      | Default     |
|--------------------------------|--------------------------------------------------|-------------|
| `-s, --volume-split`           | Split volume into X Y Z blocks                   | none        |
| `--search-x START END`         | Search range along x-axis                        | none        |
| `--search-y START END`         | Search range along y-axis                        | none        |
| `--search-z START END`         | Search range along z-axis                        | none        |
| `--z-axis-rotational-symmetry` | Z‑axis symmetry (integer)                        | none        |
| `--non-spherical-mask`         | Enable non-spherical mask support               | off         |
| `--bmask-dir`                  | Tomogram-mask dir with `<prefix>.mrc` files      | none        |
| `--tomogram-ctf-model`         | CTF model (`phase-flip`)                         | none        |
| `-r, --random-phase-correction`| STOPGAP-style random-phase correction            | off         |
| `--half-precision`             | Use float16 output                               | off         |
| `--rng-seed`                   | RNG seed for phase correction                    | `69`        |
| `--per-tilt-weighting`         | Enable per-tilt CTF weighting                    | off         |
| `--low-pass LOW_PASS`          | Low-pass filter cutoff in Å                      | none        |
| `--high-pass HIGH_PASS`        | High-pass filter cutoff in Å                     | none        |
| `--phase-shift PHASE_SHIFT`    | Phase shift in degrees (only written if > 0)     | none        |
| `--defocus-handedness`         | Defocus gradient handedness (`-1,0,1`)           | none        |
| `--spectral-whitening`         | Enable spectral whitening                        | off         |
| `--log {info,debug}`           | pytom logging verbosity                          | none        |

### Written by default!
| Flag                          | Description                                      | Default     |
|-------------------------------|--------------------------------------------------|-------------|
| `--amplitude-contrast`        | Amplitude contrast fraction                      | `0.07`      |
| `--spherical-aberration`      | Spherical aberration (mm)                        | `2.7`       |
| `--voltage`                   | Voltage (kV)                                     | `300`       |

### SLURM Settings
| Flag                          | Description                                      | Default     |
|-------------------------------|--------------------------------------------------|-------------|
| `--partition`                 | SLURM partition                                  | `emgpu`     |
| `--ntasks`                    | SLURM ntasks                                     | `1`         |
| `--nodes`                     | SLURM nodes                                      | `1`         |
| `--ntasks-per-node`           | SLURM tasks per node                             | `1`         |
| `--cpus-per-task`             | SLURM CPUs per task                              | `4`         |
| `--gres`                      | SLURM GPU resource (e.g. `gpu:1`)                | `gpu:1`     |
| `--mem`                       | SLURM memory (GB)                                | `128`       |
| `--qos`                       | SLURM Quality of Service                         | `emgpu`     |
| `--time`                      | SLURM time limit                                 | `05:00:00`  |
| `--mail-type`                 | SLURM mail notifications                         | `none`      |
| `--array-max-parallel`        | Cap concurrently running array tasks (`%N`)      | none        |
| `--exclude-nodes`             | Nodes to exclude (`#SBATCH --exclude`)           | none        |
| `--include-nodes`             | Nodes to require (`#SBATCH --nodelist`)          | none        |

---

## Example Output

### `--mode array` (default)
A single array job plus one folder per tilt-series holding its `.tlt`, defocus and exposure files:

```
submission/
├─ submit_array.sh
├─ prefixes.txt
├─ tomograms.txt
├─ Position_1/
│  ├─ Position_1.tlt
│  ├─ Position_1_defocus.txt
│  └─ Position_1_exposure.txt
├─ Position_2/
└─ Position_3/
```

Sample `submit_array.sh`:

```bash
#!/bin/bash -l
#SBATCH -D submission
#SBATCH -o pytom_%A_%a.out
##SBATCH -e pytom_%A_%a.err
#SBATCH -J pytom_tm
#SBATCH --partition=emgpu
#SBATCH --array=0-2
#SBATCH --ntasks=1
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --gres=gpu:1
#SBATCH --mail-type=none
#SBATCH --mem=128G
#SBATCH --qos=emgpu
#SBATCH --time=05:00:00

ml purge
ml pytom-match-pick

PREFIX_LIST="submission/prefixes.txt"
TOMO_LIST="submission/tomograms.txt"
OUT_DIR="submission"
TEMPLATE="/path/to/template.mrc"
PMASK="/path/to/mask.mrc"
BMASK_DIR=""
PREFIX=$(sed -n "$((SLURM_ARRAY_TASK_ID+1))p" "${PREFIX_LIST}")
TOMO=$(sed -n "$((SLURM_ARRAY_TASK_ID+1))p" "${TOMO_LIST}")
if [[ -z "${PREFIX}" ]]; then echo "Empty prefix for task ${SLURM_ARRAY_TASK_ID}"; exit 2; fi
OD="${OUT_DIR}/${PREFIX}"
mkdir -p "${OD}"
TLT="${OD}/${PREFIX}.tlt"
DF="${OD}/${PREFIX}_defocus.txt"
EXP="${OD}/${PREFIX}_exposure.txt"
if [[ -z "${TOMO}" || ! -f "${TOMO}" ]]; then echo "Tomogram not found for ${PREFIX}"; exit 2; fi
TOMO_MASK_ARGS=""
if [[ -n "${BMASK_DIR}" && -f "${BMASK_DIR}/${PREFIX}.mrc" ]]; then
  TOMO_MASK_ARGS="--tomogram-mask ${BMASK_DIR}/${PREFIX}.mrc"
fi
PHASE_ARGS=""

pytom_match_template.py \
  -v "${TOMO}" \
  -a "${TLT}" \
  --dose-accumulation "${EXP}" \
  --defocus "${DF}" \
  -t "${TEMPLATE}" \
  -d "${OD}" \
  -m "${PMASK}" \
  --angular-search 10 \
  -s 2 2 1 \
  --voxel-size-angstrom 7.64 \
  -r \
  --rng-seed 69 \
  -g 0 \
  --per-tilt-weighting \
  --tomogram-ctf-model phase-flip \
  --non-spherical-mask \
  --amplitude-contrast 0.07 \
  --spherical-aberration 2.7 \
  --voltage 300.0 \
  ${PHASE_ARGS} \
  ${TOMO_MASK_ARGS}
```

The per-tilt metadata files written into each folder look like:

```
# Position_1.tlt            # Position_1_defocus.txt   # Position_1_exposure.txt
3.0                         4.21                       0.0
-0.0                        4.18                       3.0
-3.0                        4.25                       6.0
```

## Full Help Output

Run `./warp2pytom.py -h` to see all flags and defaults. Feel free to open an issue or submit a PR for further customization!

## License

MIT

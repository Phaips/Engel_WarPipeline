#!/bin/bash
#SBATCH -o warp_export_particles_%j.out
#SBATCH -e warp_export_particles_%j.err
#SBATCH -D ./
#SBATCH -J warp_export_particles
#SBATCH --partition=emgpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=16
#SBATCH --gres=gpu:4
#SBATCH --mem=200G
#SBATCH --time=06:00:00
#SBATCH --qos=emgpu
#SBATCH --mail-type=none

set -eo pipefail
shopt -s nullglob

# =============================================================================
# USER SETTINGS
# =============================================================================

EXPORT_DIM="2d"                     # 2d = RELION --tomo particle series; 3d = subtomograms
BOX=196                             # output box size in pixels; must be even
DIAMETER_ANGSTROM=150               # particle diameter in Angstrom
COORDS_ANGPIX=6.28                  # pixel size used by input PyTom coordinates
OUTPUT_ANGPIX=1.57                  # requested particle pixel size
MAX_MISSING_TILTS=14                # used only for 2d export
PERDEVICE=1

# Parallel arrays: one entry per dataset.
DATASET_TAGS=(
    "dataset1"
)

# Each directory is normally the output folder passed to warp2pytom.py with -d.
# STAR files are read from: <PYTOM_DIR>/*/*.star
PYTOM_DIRS=(
    "/path/to/pytom/submission"
)

WARP_SETTINGS=(
    "/path/to/warp_tiltseries_dataset1.settings"
)

BASE_OUT="particles_export"
FINAL_PREFIX="particles_all"

WARP_MODULE="WarpM"
PYTOM_MODULE="pytom-match-pick"

# =============================================================================
# END USER SETTINGS
# =============================================================================

die() {
    echo "ERROR: $*" >&2
    exit 1
}

PROJECT_ROOT="$(pwd -P)"

abs_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$PROJECT_ROOT" "$path"
    fi
}

[[ "$EXPORT_DIM" == "2d" || "$EXPORT_DIM" == "3d" ]] || die "EXPORT_DIM must be 2d or 3d"
[[ "$BOX" =~ ^[0-9]+$ ]] || die "BOX must be an integer"
(( BOX >= 2 && BOX % 2 == 0 )) || die "BOX must be a positive even integer"
((${#DATASET_TAGS[@]} > 0)) || die "DATASET_TAGS is empty"
((${#DATASET_TAGS[@]} == ${#PYTOM_DIRS[@]})) || die "DATASET_TAGS and PYTOM_DIRS differ in length"
((${#DATASET_TAGS[@]} == ${#WARP_SETTINGS[@]})) || die "DATASET_TAGS and WARP_SETTINGS differ in length"

ml purge
ml "$WARP_MODULE" --ignore-cache
ml "$PYTOM_MODULE"

BASE_OUT="$(abs_path "$BASE_OUT")"
MERGED="$BASE_OUT/01_merged_pytom"
CLEAN="$BASE_OUT/02_clean_for_warp"
EXPORTED="$BASE_OUT/03_warp_export"
PARTICLE_OUT="$EXPORTED/particles"

mkdir -p "$MERGED" "$CLEAN" "$EXPORTED" "$PARTICLE_OUT"

merge_pytom_dataset() {
    local output="$1"
    shift
    local files=("$@")

    ((${#files[@]} > 0)) || die "No PyTom STAR files found for $output"

    if ((${#files[@]} == 1)); then
        cp -- "${files[0]}" "$output"
    else
        pytom_merge_stars.py -i "${files[@]}" -o "$output"
    fi
}

clean_star_for_warp() {
    local input="$1"
    local output="$2"

    python - "$input" "$output" <<'PY'
import re
import sys
from pathlib import Path

inp = Path(sys.argv[1])
out = Path(sys.argv[2])
lines = inp.read_text().splitlines()

columns = []
rows = []
inside_loop = False

for line in lines:
    stripped = line.strip()
    if not stripped:
        continue
    if stripped == "loop_":
        inside_loop = True
        continue
    if inside_loop and stripped.startswith("_"):
        columns.append(stripped.split()[0])
        continue
    if inside_loop and columns and not stripped.startswith(("#", "data_")):
        values = stripped.split()
        if len(values) >= len(columns):
            rows.append(values)

index = {name: i for i, name in enumerate(columns)}

required = [
    "_rlnCoordinateX",
    "_rlnCoordinateY",
    "_rlnCoordinateZ",
    "_rlnAngleRot",
    "_rlnAngleTilt",
    "_rlnAnglePsi",
    "_rlnLCCmax",
    "_rlnCutOff",
    "_rlnSearchStd",
    "_rlnMicrographName",
]

missing = [name for name in required if name not in index]
if missing:
    raise SystemExit(f"ERROR: missing required PyTom columns in {inp}: {missing}")

with out.open("w") as handle:
    handle.write("# Cleaned PyTom particle coordinates for WarpTools ts_export_particles\n\n")
    handle.write("data_particles\n\n")
    handle.write("loop_\n")
    for number, name in enumerate(required, start=1):
        handle.write(f"{name} #{number}\n")

    micrograph_index = required.index("_rlnMicrographName")

    for row in rows:
        values = [row[index[name]] for name in required]
        name = Path(values[micrograph_index]).name

        # Warp matches this value against the tomostar name.
        # Convert common reconstructed-tomogram names to <prefix>.tomostar.
        name = re.sub(r"\.tomostar$", "", name)
        name = re.sub(r"\.(mrc|mrcs|rec|st)$", "", name)
        name = re.sub(r"_[0-9]+(?:\.[0-9]+)?Apx.*$", "", name)
        values[micrograph_index] = name + ".tomostar"

        handle.write("\t".join(values) + "\n")
PY
}

make_star_paths_absolute() {
    local star_path="$1"
    local base_path="$2"

    python - "$star_path" "$base_path" <<'PY'
import re
import sys
from pathlib import Path

star_path = Path(sys.argv[1])
base_path = Path(sys.argv[2])

never_absolute = {
    "_rlnMicrographName",
    "_rlnTomoName",
    "_rlnOpticsGroupName",
    "_rlnGroupName",
}

path_columns = {
    "_rlnImageName",
    "_rlnCtfImage",
    "_rlnTomoParticlesFile",
    "_rlnTomoTomogramsFile",
    "_rlnTomoTiltSeriesName",
    "_rlnTomoReconstructedTomogram",
    "_rlnTomoReconstructedTomogramDenoised",
    "_rlnTomoHalfMap1",
    "_rlnTomoHalfMap2",
    "_rlnTomoMaskName",
}

def is_number(value):
    try:
        float(value)
        return True
    except ValueError:
        return False

def absolute_token(value):
    if not value or value.lower() in {"none", "null"}:
        return value
    if value.startswith("/") or re.match(r"^[A-Za-z]+://", value):
        return value
    if "@" in value:
        prefix, filename = value.split("@", 1)
        if filename.startswith("/"):
            return value
        return prefix + "@" + str((base_path / filename).resolve())
    return str((base_path / value).resolve())

output = []
columns = []
inside_loop = False

for line in star_path.read_text().splitlines():
    stripped = line.strip()

    if stripped == "loop_":
        inside_loop = True
        columns = []
        output.append(line)
        continue

    if inside_loop and stripped.startswith("_"):
        columns.append(stripped.split()[0])
        output.append(line)
        continue

    if (
        inside_loop
        and columns
        and stripped
        and not stripped.startswith(("#", "data_", "_"))
    ):
        values = line.split()
        for i, value in enumerate(values):
            if i >= len(columns):
                break
            column = columns[i]
            if column in never_absolute:
                continue
            path_syntax = "/" in value or value.startswith(("./", "../"))
            indexed_path = "@" in value and "/" in value.split("@", 1)[-1]
            if (column in path_columns or path_syntax or indexed_path) and not is_number(value):
                values[i] = absolute_token(value)
        output.append("\t".join(values))
        continue

    output.append(line)

star_path.write_text("\n".join(output) + "\n")
PY
}

merge_3d_particles() {
    local output="$1"
    shift

    python - "$output" "$@" <<'PY'
import sys
from pathlib import Path

import pandas as pd
import starfile

output = Path(sys.argv[1])
inputs = [Path(path) for path in sys.argv[2:]]

tables = []
for path in inputs:
    data = starfile.read(path, always_dict=True)
    if len(data) != 1:
        raise SystemExit(f"ERROR: expected one particle block in 3D STAR: {path}")
    tables.append(next(iter(data.values())))

starfile.write(pd.concat(tables, ignore_index=True), output)
print(f"Wrote merged 3D particle STAR: {output}")
PY
}

merge_2d_relion_tomo_stars() {
    local tag_csv="$1"
    local output_particles="$2"
    local output_tomograms="$3"
    local output_optimisation="$4"
    shift 4

    python - "$tag_csv" "$output_particles" "$output_tomograms" "$output_optimisation" "$@" <<'PY'
import sys
from pathlib import Path

import pandas as pd
import starfile

tags = sys.argv[1].split(",")
output_particles = Path(sys.argv[2]).resolve()
output_tomograms = Path(sys.argv[3]).resolve()
output_optimisation = Path(sys.argv[4]).resolve()
paths = [Path(path).resolve() for path in sys.argv[5:]]

if len(paths) != len(tags) * 2:
    raise SystemExit("ERROR: expected one particle/tomogram STAR pair per dataset")

datasets = [
    (tag, paths[2 * i], paths[2 * i + 1])
    for i, tag in enumerate(tags)
]

def normalized_key(key):
    return str(key).replace("data_", "")

def find_block(data, wanted):
    for key in data:
        if normalized_key(key) == wanted:
            return key
    raise KeyError(f"Missing data_{wanted}; available blocks: {list(data)}")

general_block = None
all_optics = []
all_particles = []
optics_maps = {}
next_optics_group = 1

for tag, particle_star, _ in datasets:
    data = starfile.read(particle_star, always_dict=True)
    optics_key = find_block(data, "optics")
    particles_key = find_block(data, "particles")

    for key in data:
        if normalized_key(key) == "general" and general_block is None:
            general_block = data[key].copy()

    optics = data[optics_key].copy()
    particles = data[particles_key].copy()

    local_map = {}
    for old_group in optics["rlnOpticsGroup"].tolist():
        local_map[str(old_group)] = next_optics_group
        next_optics_group += 1

    optics["rlnOpticsGroup"] = optics["rlnOpticsGroup"].map(
        lambda value: local_map[str(value)]
    )
    particles["rlnOpticsGroup"] = particles["rlnOpticsGroup"].map(
        lambda value: local_map[str(value)]
    )

    if "rlnOpticsGroupName" in optics.columns:
        optics["rlnOpticsGroupName"] = (
            tag + "_" + optics["rlnOpticsGroupName"].astype(str)
        )

    optics_maps[tag] = local_map
    all_optics.append(optics)
    all_particles.append(particles)

particle_blocks = {
    "optics": pd.concat(all_optics, ignore_index=True),
    "particles": pd.concat(all_particles, ignore_index=True),
}

if "rlnRandomSubset" not in particle_blocks["particles"].columns:
    particle_blocks["particles"]["rlnRandomSubset"] = [
        (index % 2) + 1 for index in range(len(particle_blocks["particles"]))
    ]

if general_block is not None:
    particle_blocks = {"general": general_block, **particle_blocks}

tomogram_blocks = {}
all_global = []

for tag, _, tomogram_star in datasets:
    data = starfile.read(tomogram_star, always_dict=True)
    global_key = find_block(data, "global")
    global_table = data[global_key].copy()
    local_map = optics_maps[tag]

    if "rlnOpticsGroup" in global_table.columns:
        global_table["rlnOpticsGroup"] = global_table["rlnOpticsGroup"].map(
            lambda value: local_map[str(value)]
        )
    if "rlnOpticsGroupName" in global_table.columns:
        global_table["rlnOpticsGroupName"] = (
            tag + "_" + global_table["rlnOpticsGroupName"].astype(str)
        )

    all_global.append(global_table)

    for key, table in data.items():
        if key == global_key:
            continue
        block = table.copy()
        if "rlnOpticsGroup" in block.columns:
            block["rlnOpticsGroup"] = block["rlnOpticsGroup"].map(
                lambda value: local_map.get(str(value), value)
            )
        tomogram_blocks[key] = block

tomogram_blocks = {
    "global": pd.concat(all_global, ignore_index=True),
    **tomogram_blocks,
}

for path in (output_particles, output_tomograms, output_optimisation):
    path.unlink(missing_ok=True)

starfile.write(particle_blocks, output_particles)
starfile.write(tomogram_blocks, output_tomograms)

output_optimisation.write_text(
    "data_\n\n"
    f"_rlnTomoParticlesFile   {output_particles}\n"
    f"_rlnTomoTomogramsFile   {output_tomograms}\n"
)

print(f"Wrote particles:    {output_particles}")
print(f"Wrote tomograms:    {output_tomograms}")
print(f"Wrote optimisation: {output_optimisation}")
PY
}

exported_particle_stars=()
exported_tomogram_stars=()
tag_csv=""

for i in "${!DATASET_TAGS[@]}"; do
    tag="${DATASET_TAGS[$i]}"
    pytom_dir="$(abs_path "${PYTOM_DIRS[$i]}")"
    settings="$(abs_path "${WARP_SETTINGS[$i]}")"

    [[ -d "$pytom_dir" ]] || die "Missing PyTom directory: $pytom_dir"
    [[ -f "$settings" ]] || die "Missing Warp settings file: $settings"

    files=("$pytom_dir"/*/*.star)
    ((${#files[@]} > 0)) || die "No STAR files found below: $pytom_dir"

    merged_star="$MERGED/particles_${tag}.star"
    clean_star="$CLEAN/particles_${tag}.star"
    warp_star="$EXPORTED/particles_${tag}_warpOUT.star"
    warp_tomogram_star="$EXPORTED/particles_${tag}_warpOUT_tomograms.star"
    processing_dir="$PARTICLE_OUT/$tag"

    echo
    echo "Dataset:       $tag"
    echo "PyTom folder:  $pytom_dir"
    echo "PyTom STARs:   ${#files[@]}"
    echo "Warp settings: $settings"

    merge_pytom_dataset "$merged_star" "${files[@]}"
    make_star_paths_absolute "$merged_star" "$pytom_dir"
    clean_star_for_warp "$merged_star" "$clean_star"

    export_args=(
        "--${EXPORT_DIM}"
        --settings "$settings"
        --input_star "$clean_star"
        --coords_angpix "$COORDS_ANGPIX"
        --output_star "$warp_star"
        --output_angpix "$OUTPUT_ANGPIX"
        --box "$BOX"
        --diameter "$DIAMETER_ANGSTROM"
        --relative_output_paths
        --output_processing "$processing_dir"
        --perdevice "$PERDEVICE"
    )

    if [[ "$EXPORT_DIM" == "2d" ]]; then
        export_args+=(--max_missing_tilts "$MAX_MISSING_TILTS")
    fi

    WarpTools ts_export_particles "${export_args[@]}"

    make_star_paths_absolute "$warp_star" "$(dirname "$warp_star")"
    exported_particle_stars+=("$warp_star")

    if [[ "$EXPORT_DIM" == "2d" ]]; then
        [[ -f "$warp_tomogram_star" ]] || die "Expected tomogram STAR not found: $warp_tomogram_star"
        make_star_paths_absolute "$warp_tomogram_star" "$(dirname "$warp_tomogram_star")"
        exported_tomogram_stars+=("$warp_tomogram_star")
    fi

    if [[ -z "$tag_csv" ]]; then
        tag_csv="$tag"
    else
        tag_csv="${tag_csv},${tag}"
    fi
done

if [[ "$EXPORT_DIM" == "3d" ]]; then
    final_star="$EXPORTED/${FINAL_PREFIX}_warpOUT.star"
    merge_3d_particles "$final_star" "${exported_particle_stars[@]}"
    make_star_paths_absolute "$final_star" "$(dirname "$final_star")"

    echo
    echo "3D subtomogram export complete:"
    echo "  STAR:      $final_star"
    echo "  particles: $PARTICLE_OUT"
else
    final_particles="$EXPORTED/${FINAL_PREFIX}_warpOUT_particles.star"
    final_tomograms="$EXPORTED/${FINAL_PREFIX}_warpOUT_tomograms.star"
    final_optimisation="$EXPORTED/${FINAL_PREFIX}_warpOUT_optimisation_set.star"

    merge_arguments=()
    for i in "${!exported_particle_stars[@]}"; do
        merge_arguments+=(
            "${exported_particle_stars[$i]}"
            "${exported_tomogram_stars[$i]}"
        )
    done

    merge_2d_relion_tomo_stars \
        "$tag_csv" \
        "$final_particles" \
        "$final_tomograms" \
        "$final_optimisation" \
        "${merge_arguments[@]}"

    make_star_paths_absolute "$final_particles" "$(dirname "$final_particles")"
    make_star_paths_absolute "$final_tomograms" "$(dirname "$final_tomograms")"

    echo
    echo "2D RELION-tomo export complete:"
    echo "  particles:    $final_particles"
    echo "  tomograms:    $final_tomograms"
    echo "  optimisation: $final_optimisation"
    echo "  image data:   $PARTICLE_OUT"
fi

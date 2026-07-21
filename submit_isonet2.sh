#!/bin/bash
#SBATCH -J isonet2
#SBATCH --partition=emgpu
#SBATCH --qos=emgpu
#SBATCH --gres=gpu:4
#SBATCH --exclude=sgp[01-04]
#SBATCH --mem=128G
#SBATCH --time=00-06:00:00
#SBATCH --cpus-per-task=16
#SBATCH -o isonet2_%j.out
#SBATCH -e isonet2_%j.err
#SBATCH -D ./

set -Eeuo pipefail
shopt -s nullglob

# =============================================================================
# USER SETTINGS
# =============================================================================

RUN_NAME="dataset"
WARP_TS="/path/to/warp_tiltseries_dataset"
TOMOSTAR_DIR="/path/to/tomostar_dataset"
MASK_SOURCE_DIR="/path/to/masks"    # expected: <prefix>.mrc or <prefix>_Vol_bmask.mrc

AC=0.07
CUBE_SIZE=96
VOLTAGE=300
EPOCHS=100
MW_WEIGHT=200
OUTPUT_NAME="CTFnetwork_box96"
WORK_ROOT="isonet2_work"

ISONET_MODULE="IsoNet/2.0.0"

# =============================================================================
# END USER SETTINGS
# =============================================================================

die() {
    echo "ERROR: $*" >&2
    exit 1
}

abs_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$(pwd -P)" "$path"
    fi
}

WARP_TS="$(abs_path "$WARP_TS")"
TOMOSTAR_DIR="$(abs_path "$TOMOSTAR_DIR")"
MASK_SOURCE_DIR="$(abs_path "$MASK_SOURCE_DIR")"
WORK_ROOT="$(abs_path "$WORK_ROOT")"

RECON="$WARP_TS/reconstruction_miss"
TILTSTACK="$WARP_TS/tiltstack"
RUN_ID="${SLURM_JOB_ID:-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="$WORK_ROOT/${RUN_NAME}_${OUTPUT_NAME}_${RUN_ID}"

[[ -d "$WARP_TS" ]] || die "Warp tilt-series directory not found: $WARP_TS"
[[ -d "$RECON/odd" ]] || die "Odd half-map directory not found: $RECON/odd"
[[ -d "$RECON/even" ]] || die "Even half-map directory not found: $RECON/even"
[[ -d "$MASK_SOURCE_DIR" ]] || die "Mask directory not found: $MASK_SOURCE_DIR"
[[ ! -e "$RUN_DIR" ]] || die "Output directory already exists: $RUN_DIR"

mkdir -p "$RUN_DIR"/{odd,even,mask}
cd "$RUN_DIR"

ml purge
ml "$ISONET_MODULE"
GPU_IDS="${CUDA_VISIBLE_DEVICES:-0}"

find_tlt_file() {
    local prefix="$1"
    local candidates=(
        "$TILTSTACK/$prefix/${prefix}_Imod/${prefix}_st.tlt"
        "$TOMOSTAR_DIR/${prefix}.tlt"
    )
    local candidate

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    mapfile -t candidates < <(
        find "$TILTSTACK" -type f \
            \( -name "${prefix}_st.tlt" -o -name "${prefix}.tlt" \) \
            2>/dev/null | sort
    )

    if ((${#candidates[@]} == 1)); then
        printf '%s\n' "${candidates[0]}"
        return 0
    fi

    return 1
}

find_mask_file() {
    local prefix="$1"
    local candidates=(
        "$MASK_SOURCE_DIR/${prefix}.mrc"
        "$MASK_SOURCE_DIR/${prefix}_Vol_bmask.mrc"
    )
    local candidate

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

mapfile -t ODD_FILES < <(
    find "$RECON/odd" -maxdepth 1 -type f -name "*Apx.mrc" | sort
)

((${#ODD_FILES[@]} > 0)) || die "No odd half maps matching *Apx.mrc in $RECON/odd"

TLT_FILES=()
DEFOCUS_A_LIST=()
PREFIXES=()

for odd_source in "${ODD_FILES[@]}"; do
    base="$(basename "$odd_source" .mrc)"
    prefix="${base%_*Apx}"

    mapfile -t even_matches < <(
        find "$RECON/even" -maxdepth 1 -type f \
            -name "${prefix}_*Apx.mrc" | sort
    )

    ((${#even_matches[@]} == 1)) || {
        printf 'ERROR: expected one even half map for %s; found %d\n' \
            "$prefix" "${#even_matches[@]}" >&2
        printf '  %s\n' "${even_matches[@]}" >&2
        exit 1
    }

    even_source="${even_matches[0]}"
    tlt_file="$(find_tlt_file "$prefix")" || die "Could not locate a unique TLT file for $prefix"
    mask_source="$(find_mask_file "$prefix")" || die "Could not locate mask for $prefix"
    xml_file="$WARP_TS/${prefix}.xml"

    [[ -f "$xml_file" ]] || die "Warp XML not found: $xml_file"

    ln -s "$(realpath "$odd_source")" "odd/${prefix}_ODD_Vol.mrc"
    ln -s "$(realpath "$even_source")" "even/${prefix}_EVN_Vol.mrc"
    ln -s "$(realpath "$mask_source")" "mask/${prefix}_Vol_bmask.mrc"

    defocus_um="$(
        sed -n 's/.*Name="Defocus" Value="\([^"]*\)".*/\1/p' "$xml_file" |
        head -n 1
    )"

    [[ -n "$defocus_um" ]] || die "Could not read Defocus from $xml_file"

    defocus_angstrom="$(
        awk -v defocus="$defocus_um" 'BEGIN {printf "%.2f", defocus * 10000.0}'
    )"

    TLT_FILES+=("$tlt_file")
    DEFOCUS_A_LIST+=("$defocus_angstrom")
    PREFIXES+=("$prefix")
done

tilt_min="$(
    awk 'NR == 1 || $1 < minimum {minimum = $1}
         END {printf "%.2f", minimum}' "${TLT_FILES[@]}"
)"
tilt_max="$(
    awk 'NR == 1 || $1 > maximum {maximum = $1}
         END {printf "%.2f", maximum}' "${TLT_FILES[@]}"
)"
defocus_csv="$(IFS=,; echo "${DEFOCUS_A_LIST[*]}")"

echo "IsoNet2 prefixes:"
printf '  %s\n' "${PREFIXES[@]}"
echo "tilt_min:  $tilt_min"
echo "tilt_max:  $tilt_max"
echo "defocus_A: [$defocus_csv]"
echo "AC:        $AC"
echo "cube_size: $CUBE_SIZE"
echo "GPU IDs:   $GPU_IDS"
echo "run dir:   $RUN_DIR"

STAR_FILE="tomograms_${OUTPUT_NAME}.star"
NETWORK_DIR="isonet2_out_${OUTPUT_NAME}"

isonet.py prepare_star \
    --even even/ \
    --odd odd/ \
    --mask_folder mask/ \
    --tilt_min "$tilt_min" \
    --tilt_max "$tilt_max" \
    --defocus "[$defocus_csv]" \
    --ac "$AC" \
    --voltage "$VOLTAGE" \
    --star_name "$STAR_FILE"

time isonet.py refine \
    "$STAR_FILE" \
    -o "$NETWORK_DIR" \
    --method isonet2-n2n \
    --cube_size "$CUBE_SIZE" \
    --epochs "$EPOCHS" \
    --mw_weight "$MW_WEIGHT" \
    --CTF_mode network \
    --clip_first_peak_mode 1 \
    --isCTFflipped True \
    --gpuID "$GPU_IDS"

MODEL="$NETWORK_DIR/network_isonet2-n2n_unet-medium_${CUBE_SIZE}_full.pt"
[[ -f "$MODEL" ]] || die "Expected trained model not found: $MODEL"

time isonet.py predict \
    "$STAR_FILE" \
    "$MODEL" \
    --gpuID "$GPU_IDS"

echo "IsoNet2 output written to: $RUN_DIR"

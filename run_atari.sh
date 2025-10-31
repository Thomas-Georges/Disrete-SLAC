#!/usr/bin/env bash
# run_atari.sh — sequential overnight launcher for SLAC_atari_deterministic.py
# - Tyro booleans handled correctly ( --flag / --no-flag )
# - Uses a command array to avoid "flags on a new line" bugs
# - Optional W&B entity/group; omitted if empty (prevents parser errors)
# - Optional tqdm throttling and thread limits (off by default)
# - Captures Python exit code even when piping through tee

set -Eeuo pipefail

### ─────────────────────── User-configurable section ─────────────────────── ###
# 8 popular Atari games (Gymnasium ALE v5 IDs)
GAMES=(
  #"ALE/Pong-v5"
  "ALE/Breakout-v5"
  "ALE/SpaceInvaders-v5"
  "ALE/Qbert-v5"
  "ALE/Seaquest-v5"
  "ALE/MsPacman-v5"
  "ALE/BeamRider-v5"
  "ALE/Enduro-v5"
  "ALE/Pong-v5"

)

# Seeds to try
SEEDS=(1)

# W&B project (set to "" to disable passing it on the CLI)
WANDB_PROJECT="SLAC_Atari_First_Try"
# If you want to force a specific workspace, set this to your username/team slug; else leave empty
WANDB_ENTITY=""        # e.g., "your-username" or "your-team"; "" lets wandb infer from login
# Optional: group name to cluster these runs together; empty disables the flag entirely
WANDB_GROUP="batch_$(date +%Y%m%d_%H%M)"  # set "" to skip passing --wandb_group

# Logging
LOGDIR="logs_atari_batch"
mkdir -p "$LOGDIR"

# Performance toggles (defaults chosen for single-job speed)
LIMIT_THREADS="false"     # "true" to cap CPU libs; "false" to leave them uncapped
TQDM_THROTTLE="true"      # reduce progress-bar update frequency when logging to file

# W&B connectivity (choose one or leave both empty)
# export WANDB_MODE=offline     # log locally; sync later
# export WANDB_DISABLED=true    # completely disable W&B
### ───────────────────────────────────────────────────────────────────────── ###

# Optional thread limits (turn ON only when launching many concurrent jobs)
if [[ "$LIMIT_THREADS" == "true" ]]; then
  # On macOS, sysctl below works; on Linux, fall back to nproc
  PHYS_CORES="$( (sysctl -n hw.physicalcpu 2>/dev/null || nproc) || echo 4 )"
  export OMP_NUM_THREADS="$PHYS_CORES"
  export MKL_NUM_THREADS="$PHYS_CORES"
  export PYTORCH_NUM_THREADS="$PHYS_CORES"
  export KMP_BLOCKTIME=0
else
  unset OMP_NUM_THREADS MKL_NUM_THREADS PYTORCH_NUM_THREADS KMP_BLOCKTIME || true
fi

# Throttle tqdm to cut log I/O overhead
if [[ "$TQDM_THROTTLE" == "true" ]]; then
  export TQDM_MININTERVAL=1.0
  export TQDM_MINITERS=10
fi

export PYTHONUNBUFFERED=1

# Helper: append an arg if the value is non-empty
append_if_set() {
  # $1 = flag name (e.g., --wandb_entity), $2 = value, args array name in $3
  local flag="$1" val="$2" arrname="$3"
  if [[ -n "$val" ]]; then
    eval "$arrname+=(\"$flag\" \"$val\")"
  fi
}

for ENV_ID in "${GAMES[@]}"; do
  # Tyro-style booleans: present = True, --no-flag = False
  if [[ "$ENV_ID" == "ALE/Pong-v5" ]]; then
    PONG_FLAGS=(--pong_rally_done --use_action_subset)
  else
    PONG_FLAGS=(--no-pong_rally_done --no-use_action_subset)
  fi

  for SEED in "${SEEDS[@]}"; do
    NAME="$(basename "$ENV_ID")-s${SEED}"
    echo "=== Launching $ENV_ID (seed=$SEED) ==="

    # Build the command as an array (robust to spaces/newlines)
    cmd=(python SLAC_atari_deterministic.py
      --env_id "$ENV_ID"
      --seed "$SEED"
    )

    # Optional W&B flags (only passed if non-empty to avoid parser errors)
    append_if_set --wandb_project_name "$WANDB_PROJECT" cmd
    append_if_set --wandb_entity       "$WANDB_ENTITY"  cmd
    append_if_set --wandb_group        "$WANDB_GROUP"   cmd

    # Pong flags last
    cmd+=("${PONG_FLAGS[@]}")

    # (Optional) print the exact command
    printf 'CMD: '; printf '%q ' "${cmd[@]}"; echo

    # Run and capture python's exit code even through tee
    { "${cmd[@]}"; } 2>&1 | tee "${LOGDIR}/${NAME}.log"
    status=${PIPESTATUS[0]}
    if [[ $status -ne 0 ]]; then
      echo "✗ ${ENV_ID} seed ${SEED} exited with code ${status}" | tee -a "${LOGDIR}/${NAME}.log"
      # Uncomment to stop on first failure:
      # exit $status
    else
      echo "✓ ${ENV_ID} seed ${SEED} finished OK"
    fi
  done
done

echo "All jobs finished. Logs in $LOGDIR/"

#!/bin/bash

# Functions
# ---------
change_param(){
    sed -i 's/\(^\s*'"${2}"'\s*=\s*\).*$/\1'"${3}"'/g' ${1}
}

error(){
    echo $1
    exit 1
}

# User settings
# -------------
# If no user_settings file, use defaults (better design for version control)
[[ -f user_settings ]] || ln -s user_settings_defaults user_settings
source user_settings

# Check executables and environments
# ----------------------------------
check_files="cosmo cesm.exe cosmo_env.sh"
missing_files=""
for f in ${check_files}; do
    [[ -e $f ]] || missing_files+=" $f"
done
[[ -n ${missing_files} ]] && error "ERROR missing file(s):${missing_files}"

valid_compilers="gcc nvhpc"
if [[ ${valid_compilers} != *"${cesm_compiler}"* ]]; then
    error "CESM compiler ${cesm_compiler} not valid, should be in ${valid_compilers}"
else
    ln -s ../cesm_${cesm_compiler}_env.sh cesm_env.sh
fi

# Clean up
# --------
# cosmo
rm -f YU*
# log
rm -f nout.000000 debug.0[1-2].* core.* *.log
# oasis
rm -f grids.nc masks.nc areas.nc rmp*.nc
# output
rm -rf cosmo_output/*
rm -rf cesm_output/*

# Make missing COSMO directories
# ------------------------------
for ydir in $(sed -n 's/^\s*ydir.*=\s*["'\'']\(.*\)["'\'']\s*/\1/p' INPUT_IO); do
    mkdir -p ${ydir}
done

# Transfer input files
# --------------------
rsync -av ${cesm_input_folder}/ ./cesm_input/
rsync -av ${cosmo_input_folder}/ ./cosmo_input/

# Distribute tasks
# ----------------
# Compute tasks and check
[[ ${cosmo_target} == gpu ]] && ((nodes = nprocx * nprocy + nprocio))
((ntasks = nodes * 12))
((ntasks_cosmo = nprocx * nprocy + nprocio))
((ntasks_cesm = ntasks - ntasks_cosmo))
if [[ ${cosmo_target} == cpu ]] && ((ntasks_cesm <= 0)); then
    error "missmatch in tasks distributions : nprocx * nprocy + nprocio >= nodes * 12"
fi
echo "using ${nodes} nodes with ${ntasks_cosmo} cosmo tasks and ${ntasks_cesm} cesm tasks"

# build task id list for cosmo and cesm
if [[ ${cosmo_target} == cpu ]]; then
    cosmo_tasks="0-$((ntasks_cosmo-1))"
    cesm_tasks="${ntasks_cosmo}-$((ntasks-1))"
elif [[ ${cosmo_target} == gpu ]]; then
    cosmo_tasks=""
    cesm_tasks=""
    for ((k=0; k<nodes; k++)); do
        ((n0 = k*12))
        ((n1 = n0+1))
        ((n2 = n0+11))
        cosmo_tasks+="${n0},"
        cesm_tasks+="${n1}-${n2},"
    done
    # remove trailing comma
    cosmo_tasks=${cosmo_tasks:0:-1}
    cesm_tasks=${cesm_tasks:0:-1}
fi
# write task dispatch file
cat > prog_config << EOF
${cosmo_tasks} ./cosmo.sh
${cesm_tasks} ./cesm.sh
EOF

# Adapt namelists
# ---------------
# COSMO
change_param INPUT_ORG 'nprocx' ${nprocx}
change_param INPUT_ORG 'nprocy' ${nprocy}
change_param INPUT_ORG 'num_asynio_comm' ${nprocio}
if (( nprocio > 0 )); then
    [[ ${cosmo_target} == gpu ]] &&  export COSMO_NPROC_NODEVICE=${nprocio}
    change_param INPUT_ORG 'num_iope_percomm' 1
    change_param INPUT_IO 'lasync_io' .true.
else
    change_param INPUT_ORG 'num_iope_percomm' 0
    change_param INPUT_IO 'lasync_io' .false.
    change_param INPUT_IO 'lprefetch_io' .false.
fi
change_param INPUT_ORG 'hstop' ${hstop}
[[ ${cosmo_target} == gpu ]] && lcpp_dycore=.true. || lcpp_dycore=.false.
# CESM
change_param INPUT_DYN 'lcpp_dycore' ${lcpp_dycore}
change_param drv_in '.*_ntasks' ${ntasks_cesm}
change_param drv_in 'stop_n' $((hstop*3600))

# Submit job
# ----------
sbatch --account=${account} --time=${time} --nodes=${nodes} --constraint=gpu --partition=${partition} --job-name=CCLM2 --output="%x.log" --wrap "srun -u --multi-prog ./prog_config"

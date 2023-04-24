#!/bin/bash

# Set up
# ------
cosmo_target=cpu
nodes=4
if [[ ${cosmo_target} == cpu ]]; then
    nprocx=6
    nprocy=6
elif [[ ${cosmo_target} == cpu ]]; then
    nprocx=2
    nprocy=2
fi

# Check for executables
# ---------------------
check_files="cosmo cesm.exe cosmo_env.sh cesm_env.sh"
missing_files=""
for f in ${check_files}; do
    [[ -e $f ]] || missing_files+=" $f"
done
if [[ -n ${missing_files} ]]; then
    echo "ERROR missing file(s):${missing_files}"
    exit 1
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
rsync -av /project/sm61/leclairm/CCLM2_sandbox_inputdata/cesm_input_044/ ./cesm_input/
rsync -av /project/sm61/leclairm/CCLM2_sandbox_inputdata/cosmo_input_011/ ./cosmo_input/

# Distribute tasks
# ----------------
# Compute tasks and check
((ntasks = nodes * 12))
((ntasks_cosmo = nprocx * nprocy))
((ntasks_cesm = ntasks - ntasks_cosmo))
if [[ ${cosmo_target} == cpu ]]; then
    if ((ntasks_cesm <= 0)); then
        echo "missmatch in tasks distributions : nprox * nprocy >= nodes * 12"
        exit 1
    fi
elif [[ ${cosmo_target} == gpu ]]; then
    if ((nprox * nprocy > nodes)); then
        echo "missmatch in tasks distributions: nprox * nprocy > nodes"
        exit 1
    fi
fi
echo "using ${nodes} nodes with ${ntasks_cosmo} cosmo tasks and ${ntasks_cesm} cesm tasks"

# build task dispatch file
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
    cosmo_tasks=${cosmo_tasks:0:-1}
    cesm_tasks=${cesm_tasks:0:-1}
fi
cat > prog_config << EOF
${cosmo_tasks} ./cosmo.sh
${cesm_tasks} ./cesm.sh
EOF

# Adapt namelists
# ---------------
sed -i 's/\(^\s*nprocx\s*=\s*\).*$/\1'"${nprocx}"'/' INPUT_ORG
sed -i 's/\(^\s*nprocy\s*=\s*\).*$/\1'"${nprocy}"'/' INPUT_ORG
sed -i 's/\(^\s*.*_ntasks\s*=\s*\).*$/\1'"${ntasks_cesm}"'/g' drv_in
[[ ${cosmo_target} == gpu ]] && lcpp_dycore=.true. || lcpp_dycore=.false.
sed -i 's/\(^\s*lcpp_dycore\s*=\s*\).*$/\1'"${lcpp_dycore}"'/' INPUT_DYN

# Submit job
# ----------
sbatch --account=sm61 --time=00:30:00 --nodes=${nodes} --constraint=gpu --partition=debug --job-name=CCLM2 --output="%x.log"  --wrap "srun -u --multi-prog ./prog_config"

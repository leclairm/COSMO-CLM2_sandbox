#!/bin/bash

source cesm_env.sh
./cesm.exe 2>&1 > cesm_$(printf %0${#SLURM_NTASKS}d ${SLURM_PROCID}).log

#!/bin/bash

source cosmo_env.sh
./cosmo 2>&1 > cosmo_$(printf %0${#SLURM_NTASKS}d ${SLURM_PROCID}).log

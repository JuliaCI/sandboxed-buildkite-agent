#!/bin/bash

julia --project build_systemd_config.jl $(hostname).0 --debug --verbose

#!/bin/sh
echo "-> Setting hostname to ${SANITIZED_HOSTNAME}"
hostname "${SANITIZED_HOSTNAME}"

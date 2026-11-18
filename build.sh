#!/bin/sh

level=""

case $1 in
release) level="-o:speed" ;;
debug | *) level="-debug -o:none" ;;
esac

odin build client -out:client-bin ${level}
odin build server -out:server-bin ${level}

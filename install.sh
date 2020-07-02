#!/bin/bash

set -e

# ref: https://stackoverflow.com/a/7359006
USER_HOME=$(getent passwd $SUDO_USER | cut -d: -f6)

# ref: https://askubuntu.com/a/30157/8698
if ! [ $(id -u) = 0 ]; then
    echo "The script need to be run as root." >&2
    exit 1
fi

if [ $SUDO_USER ]; then
    real_user=$SUDO_USER
else
    real_user=$(whoami)
fi

printf "Thank you for installing hsh, $real_user!\n"

printf "Building the shell from sources...\n"

STACK_CMD="sudo -u $real_user stack"

$STACK_CMD build

printf "Installing the shell executable\n"

EXE_BUILD_LOC=$($STACK_CMD exec -- which hsh)
cp $EXE_BUILD_LOC /bin

if ! grep hsh /etc/shells &> /dev/null; then
    printf "Updating /etc/shells...\n"
    echo "/bin/hsh" | tee -a /etc/shells
fi

echo "Copying default settings to ~/.hshrc..."
DEFAULT_HSHRC_PATH="conf/.hshrc"
if ! cp $DEFAULT_HSHRC_PATH $USER_HOME &> /dev/null; then
    echo "Warning: missing file $DEFAULT_HSHRC_PATH"
fi

echo -n "Update default shell for user $real_user (y/n)? "
read answer
if [ "$answer" != "${answer#[Yy]}" ] ; then
    printf "Changing user's default shell...\n"
    sudo -u $real_user chsh -s /bin/hsh
fi
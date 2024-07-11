#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install a package based on the package manager
install_package() {
    local package="$1"
    if command_exists apt-get; then
        sudo apt-get update && sudo apt-get install -y "$package"
    elif command_exists dnf; then
        sudo dnf install -y "$package"
    elif command_exists pacman; then
        sudo pacman -S --noconfirm "$package"
    else
        echo "Unsupported package manager. Please install $package manually."
        return 1
    fi
}

# Function to install ADB
install_adb() {
    install_package android-tools-adb || install_package android-tools
}

# Function to ensure either curl or wget is available
ensure_download_tool() {
    if ! command_exists curl && ! command_exists wget; then
        echo "Neither curl nor wget is installed. Attempting to install curl..."
        if install_package curl; then
            echo "curl installed successfully."
        else
            echo "Failed to install curl. Attempting to install wget..."
            if install_package wget; then
                echo "wget installed successfully."
            else
                echo "Failed to install both curl and wget. Unable to download package list."
                return 1
            fi
        fi
    fi
    return 0
}

# Function to download the package list from GitHub
download_package_list() {
    local github_raw_url="https://raw.githubusercontent.com/ich-bin-fr0st/ProxyJacker-removal--Android/main/known.lst"
    local temp_file="known_temp.lst"

    if command_exists curl; then
        if ! curl -f -s -o "$temp_file" "$github_raw_url"; then
            if [ $? -eq 22 ]; then
                echo "Error 404: Package list file not found on GitHub."
            else
                echo "Failed to download package list from GitHub."
            fi
            return 1
        fi
    elif command_exists wget; then
        if ! wget -q -O "$temp_file" "$github_raw_url"; then
            if grep -q "404: Not Found" "$temp_file"; then
                echo "Error 404: Package list file not found on GitHub."
                rm -f "$temp_file"
            else
                echo "Failed to download package list from GitHub."
            fi
            return 1
        fi
    else
        echo "Neither curl nor wget is available. This shouldn't happen."
        return 1
    fi

    if [ -s "$temp_file" ]; then
        mv "$temp_file" known.lst
        echo "Successfully downloaded and updated known.lst"
        return 0
    else
        rm -f "$temp_file"
        echo "Downloaded file is empty."
        return 1
    fi
}

# Function to wait for device to reconnect
wait_for_device() {
    local timeout=30
    local start_time=$(date +%s)
    echo "Waiting for device to reconnect..."
    while ! adb shell exit >/dev/null 2>&1; do
        if [ $(($(date +%s) - start_time)) -ge $timeout ]; then
            echo "Timeout waiting for device to reconnect."
            return 1
        fi
        sleep 1
    done
    echo "Device reconnected successfully."
    return 0
}

# Check if ADB is installed
if ! command_exists adb; then
    echo "ADB is not installed. Do you want to install it? (y/n)"
    read -r install_choice
    if [ "$install_choice" = "y" ]; then
        install_adb
    else
        echo "ADB installation skipped. Exiting."
        exit 0
    fi
fi

# Check if the device is connected
adb devices | grep -q "device$"
if [ $? -ne 0 ]; then
    echo "No Android device connected. Please connect a device and try again."
    exit 1
fi

# Ensure we have a tool to download the package list
if ensure_download_tool; then
    echo "Attempting to download updated package list from GitHub..."
    if ! download_package_list; then
        echo "Continuing with local known.lst if available."
    fi
else
    echo "Unable to download package list. Continuing with local known.lst if available."
fi

# Check if known.lst exists
if [ ! -f known.lst ]; then
    echo "Error: known.lst file not found. Please create a list of packages to check."
    exit 1
fi

# Read packages from known.lst
mapfile -t packages < known.lst

# Check if packages are installed on the Android device
installed_packages=()
for package in "${packages[@]}"; do
    if adb shell pm list packages -3 | grep -q "$package"; then
        installed_packages+=("$package")
    fi
done

# If installed packages found, prompt for uninstallation
if [ ${#installed_packages[@]} -gt 0 ]; then
    echo "The following packages were found:"
    printf '%s\n' "${installed_packages[@]}"
    echo "Do you want to uninstall them? (y/n)"
    read -r uninstall_choice
    
    if [ "$uninstall_choice" = "y" ]; then
        failed_packages=()
        for package in "${installed_packages[@]}"; do
            if ! adb shell pm uninstall "$package"; then
                failed_packages+=("$package")
            fi
        done
        
        # Retry failed packages with root
        if [ ${#failed_packages[@]} -gt 0 ]; then
            echo "Some packages failed to uninstall. Retrying with root..."
            adb root
            if wait_for_device; then
                for package in "${failed_packages[@]}"; do
                    adb shell pm uninstall "$package"
                done
            else
                echo "Failed to reconnect to the device. Some packages may not have been uninstalled."
            fi
        fi
    else
        echo "Uninstallation skipped."
    fi
else
    echo "No packages from known.lst found on the device."
fi

echo "Script execution completed."

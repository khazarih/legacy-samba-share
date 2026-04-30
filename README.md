# Legacy System File Share

This project implements a secure file sharing solution using Samba. A Red Hat 9.7 server bridges a modern "Office" network and an isolated "Legacy" network using SMB file shares with different protocol versions and security configurations.


### High Level Architecture

![High Level Architecture](/static/architecture.png)

## Security Hardening

*   **Network Isolation**: The Office and Legacy networks are on separate internal networks. No routing is enabled between them.
*   **Firewall Zoning**: `firewalld` on Red Hat 9.7 restricts SMB services per interface:
    - **Office Zone**: Only SMB3 (modern protocol) is allowed on the office interface.
    - **Legacy Zone**: Only SMB1/NT1 (legacy protocol) is allowed on the legacy interface.
*   **Dual SMB Configuration**: Separate Samba services (`samba-office` and `samba-legacy`) with isolated configurations:
    - `samba-office`: SMB3-only, serves `/samba/office`, authenticated with `office_user`
    - `samba-legacy`: NT1/SMB1-only, serves `/samba/legacy`, authenticated with `legacy_user`
*   **No-Execute Enforcement**:
    - Filesystem-level protection using an XFS partition mounted with `noexec`.
    - Samba-level protection using `acl allow execute always = no` and restrictive file masks.
*   **User Isolation**: Dedicated system users for each share with restricted permissions.

## Getting Started

### Prerequisites

*   Red Hat 9.7 system with at least two network interfaces and one available disk.
*   Root access to run `setup.sh`.


### Installation Steps

1.  **Prepare the System**:
    - Ensure Red Hat 9.7 is installed with two network interfaces (one for office network, one for legacy network).
    - Identify the network interface names and the disk to be used for the SMB share (e.g., `nvme0n2`).

2.  **Run the Setup Script**:
    ```bash
    sudo bash setup.sh <office_interface> <legacy_interface> <disk_name>
    ```
    **Example**:
    ```bash
    sudo bash setup.sh enp2s0 enp10s0 nvme0n2
    ```

    The script will:
    - Install required packages (Samba, XFS tools, firewall, inotify tools, etc.)
    - Create and format the XFS partition
    - Mount it at `/samba`
    - Create `office` and `legacy` share directories
    - Configure separate Samba services for each network
    - Set up firewall zones and restrict services per interface
    - Install a systemd service that bidirectionally moves completed files between the office and legacy shares
    - Generate random passwords for `office_user` and `legacy_user`
    - Output the credentials for both shares

3.  **Retrieve Credentials**:
    - The script outputs usernames and passwords. Store these securely.
    - **Legacy Share**: Use `legacy_user` and provided password to access `\\<server>\legacy` via SMB1.
    - **Office Share**: Use `office_user` and provided password to access `\\<server>\office` via SMB3.

4.  **Verify**:
    - Connect from the office client to `\\<red_hat_ip>\office` using `office_user`.
    - Connect from the legacy client to `\\<red_hat_ip>\legacy` using `legacy_user`.
    - Test file reading and writing on both shares.
    - Verify that executable files cannot be executed from either share (no-execute protection).

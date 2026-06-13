# Running Blockheads Server on Windows

This guide covers how to run the Blockheads server on Windows 10 and Windows 11 using Windows Subsystem for Linux (WSL).

## Prerequisites

- Windows 10 (version 2004 or higher) or Windows 11
- WSL 2 installed with a Linux distribution (Ubuntu is recommended)
- Administrative privileges

## Installation Steps

### 1. Install WSL 2

If you haven't already installed WSL 2, run the following commands in PowerShell as Administrator:

```powershell
wsl --install
```

Restart your computer when prompted and complete the Ubuntu setup.

### 2. Set Up the Blockheads Server

Open your WSL Ubuntu terminal and follow these steps:

Download the installer script:
```bash
curl -s -o installer.sh https://cdn.jsdelivr.net/gh/NovaDev404/blockheads-server@main/installer.sh
```

Make the script executable:
```bash
chmod +x installer.sh
```

Install the server:
```bash
./installer.sh --install
```

### 3. Run the Server

Start the Blockheads server:
```bash
./blockheads_server171
```

By default, the server runs on port 15151.

## Local Forwarding (For Network Access)

To make your Blockheads server accessible from other devices on your local network (LAN), you need to forward ports from Windows to WSL.

Choose the method based on your Windows version:

### Method 1: Mirrored Networking (Windows 11 only) - Recommended

Windows 11 supports a feature that shares the Windows host's IP directly with WSL, allowing it to act like an actual physical device on your LAN.

1. **Create or open the `.wslconfig` file** in your Windows user profile folder:
   ```
   C:\Users\YourUsername\.wslconfig
   ```

2. **Add the following lines** to enable mirrored mode:
   ```ini
   [wsl2]
   networkingMode=mirrored
   dnsTunneling=true
   firewall=true
   ```

3. **Apply the settings** by opening a terminal and running:
   ```bash
   wsl --shutdown
   ```

4. **Restart WSL** and your Blockheads server will now directly share your Windows IP. Other devices can connect via your standard PC IP address and port 15151.

### Method 2: Netsh Port Forwarding (Windows 10 & 11)

WSL 2 uses a randomized, dynamic virtual IP that changes every time you restart your PC. To make port forwarding permanent across reboots, you can map the ports using netsh and a startup script.

#### Step 1: Setup the Firewall

Allow incoming LAN traffic on port 15151:

1. Open PowerShell as Administrator
2. Run this command:
   ```powershell
   New-NetFirewallRule -DisplayName "WSL2 Blockheads Server" -Direction Inbound -LocalPort 15151 -Action Allow -Protocol TCP
   ```

#### Step 2: Create the Port Proxy Rule

1. **Find your WSL internal IP** by opening your WSL terminal and running:
   ```bash
   hostname -I
   ```

2. **Map the traffic to WSL** using netsh in Administrator PowerShell:
   ```powershell
   netsh interface portproxy add v4tov4 listenport=15151 listenaddress=0.0.0.0 connectport=15151 connectaddress=[WSL_IP]
   ```

   Example:
   ```powershell
   netsh interface portproxy add v4tov4 listenport=15151 listenaddress=0.0.0.0 connectport=15151 connectaddress=172.26.16.5
   ```

#### Step 3: Automate the Process (Permanent)

Because the WSL IP changes on every restart, automate this script to run at every user login.

1. **Create the PowerShell script**:
   Save the following as `wsl-port-forward.ps1` in a safe location (e.g., `C:\Scripts\wsl-port-forward.ps1`):

   ```powershell
   # Get dynamic WSL IP
   $wsl_ip = bash.exe -c "hostname -I | awk '{print \$1}'"

   # Delete old proxy to prevent duplicates
   netsh interface portproxy delete v4tov4 listenport=15151 listenaddress=0.0.0.0 | Out-Null

   # Add current proxy
   netsh interface portproxy add v4tov4 listenport=15151 listenaddress=0.0.0.0 connectport=15151 connectaddress=$wsl_ip
   ```

2. **Set up Task Scheduler**:
   - Open Task Scheduler (search for it in Start)
   - Click "Create Basic Task" on the right
   - Name it "WSL Blockheads Port Forward" and click Next
   - Set trigger to "When I log on" and click Next
   - Set action to "Start a program" and click Next
   - In "Program/script", type: `powershell.exe`
   - In "Add arguments", type: `-WindowStyle Hidden -File C:\Scripts\wsl-port-forward.ps1`
   - Check "Open the Properties dialog for this task when I click Finish"
   - Click Finish
   - In the Properties dialog, check "Run with highest privileges"
   - Click OK

Now the port forwarding will be automatically configured every time you log in.

## Connecting to Your Server

Once port forwarding is set up, other devices on your network can connect to your Blockheads server using:

- **Windows IP address** and port 15151
- Example: `192.168.1.100:15151` or `10.1.1.204:15151`

### Finding Your Local IP Address

Your local IP address (the IP other devices on your network use to connect) is your Windows machine's IP address, not the WSL IP.

**To find your Windows IP address:**

1. Open Command Prompt or PowerShell
2. Run: `ipconfig`
3. Look for the IPv4 Address under your active network adapter (Ethernet or Wi-Fi)

Common local IP formats:
- `192.168.x.x` (most common home networks)
- `10.x.x.x` (enterprise or some home networks)
- `172.16.x.x` to `172.31.x.x` (less common)

This is the IP address other devices on your local network should use to connect to your Blockheads server.

## Public Access (Outside Your Local Network)

By default, your Blockheads server is only accessible from devices within your local network (LAN). To make it accessible from outside (e.g., from friends' homes, mobile data, etc.), you have three options:

### Option 1: IPv6 (Recommended if Available)

If your internet service provider supports IPv6, you can use your IPv6 address directly without additional configuration.

**To find your IPv6 address:**
1. Visit a site like [test-ipv6.com](https://test-ipv6.com) to check if you have IPv6
2. If available, use `ipconfig` in Command Prompt to find your IPv6 address
3. Share this IPv6 address with port 15151 (e.g., `[2001:db8::1]:15151`)

### Option 2: Router Port Forwarding

Forward port 15151 from your router to your Windows machine.

**Steps:**
1. Log into your router's admin panel (usually at `192.168.1.1`, `192.168.0.1`, or `10.1.1.1`)
2. Find the "Port Forwarding" or "Virtual Server" section
3. Create a new rule:
   - External port: 15151
   - Internal port: 15151
   - Internal IP: Your Windows local IP (e.g., `192.168.1.100`)
   - Protocol: TCP
4. Save and apply changes
5. Share your public IP address with port 15151

**To find your public IP:**
- Visit a site like [whatismyipaddress.com](https://whatismyipaddress.com)

⚠️ **Security Note:** Port forwarding exposes your server to the internet. Consider:
- Using a strong password for your server
- Keeping the server updated
- Monitoring logs for suspicious activity
- Using a firewall to restrict access

### Option 3: Tunneling Services (Easiest and Safest)

Use a tunneling service that provides a public URL without router configuration.

**Popular options:**
- **ngrok**: Creates a secure tunnel to your localhost
  - Download: [ngrok.com](https://ngrok.com)
  - Run: `ngrok tcp 15151`
  - Share the provided URL (e.g., `tcp://0.tcp.ngrok.io:12345`)

- **Cloudflare Tunnel**: Free, secure, no software installation
  - Use Cloudflare's zero-trust service to expose your server
  - Works with your own domain if you have one

- **Tailscale**: Creates a private network between devices
  - Install Tailscale on both the server and client devices
  - Connects directly without exposing to public internet

**Recommendation:** For most users, **ngrok** or **Tailscale** is the easiest and safest option for occasional public access. For permanent public servers, consider router port forwarding with proper security measures.

## Uninstalling

To uninstall the Blockheads server and dependencies:

```bash
./installer.sh --uninstall
```

## Troubleshooting

### Server not accessible from network

1. Verify the WSL IP is correct:
   ```bash
   hostname -I
   ```

2. Check if port forwarding is active:
   ```powershell
   netsh interface portproxy show v4tov4
   ```

3. Test the connection locally:
   ```bash
   curl http://localhost:15151
   ```

### WSL IP changes after restart

Use Method 2 with the automated startup script to handle dynamic IP changes.

### Firewall blocking connections

Ensure the firewall rule was created:
```powershell
Get-NetFirewallRule -DisplayName "WSL2 Blockheads Server"
```

## Additional Resources

- [Official WSL documentation](https://docs.microsoft.com/en-us/windows/wsl/)
- [Blockheads Server README](README.md) for general usage instructions
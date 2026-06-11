# Configuration files for automatic deployment of mac CI runners

These are configuration files for MDS (https://twocanoes.com/products/mac/mac-deploy-stick/) to quickly setup a new mac in the
way that CI expects. 

# Instructions to build a deployment image (.dmg)

N.B.: These steps are only required once to rebuild the image. If you're setting up additional macs, using an already-built deployment image is fine.

1. Obtain Xcode from https://developer.apple.com/download/all/?q=xcode
	1a. Extract xcode.xip and move the resulting .app into the packages/ subfolder of this directory
2. Downloads MDS (N.B. at time of this writing, only MDS 5 works for macOS >= 13). The default version of
   MDS is 4. MDS 5 downloads can be found at https://bitbucket.org/twocanoes/macdeploystick/downloads/.
3. Use MDS' "Download macos" feature to download the appropriate version of macos for CI. The currently recommended macOS version is 13.3.1.
   Place the downloaded file in this folder.
4. Import the MDS workflow file found in this folder (setupci.mdsworkflows). You may need to make the following changes (hit "Edit" after importing the workflow0:
   4a. Adjust the paths for (i) macos Installer (ii) packages (iii) resources to match this folder or its subdirectories.
   	   (MDS uses absolute paths in its settings).
   4b. Set a password for the `julia` user. This password is not used in CI, but will be used for SSH.
   4c. If your mac is connected via wifi, enter wifi credentials in the workflow options.
5. Hit "Save to disk image" and choose an easy to remember name. Shorter names are better as you will need to type the name later on each machine.
   5a. It is recommended to set the "Automatically run workflow with name" option to save manual effort. 
6. Serve the resulting disk image via http at a location accessible to the new mac. (In this writeup we will assume it's at `http://192.168.1.1`).

# Instructions for deploying an image

1. Put the mac into recovery mode (Cmd-R on Intel mac, hold the power button on Apple Silicon)
2. Open the terminal and enter:
```
hdiutil mount http://192.168.1.1/img.dmg
/Volumes/mdsresources/run
```
3. Select the workflow (or wait for it to run if selected above)
4. (On Apple Silicon only). The mac may need to be erased. Follow onscreen instructions. The mac will have to be connected to internet for activation.
5. Wait.
6. (On Apple Silicon only). Manually accept the license agreement and select the target disk.
7. Wait.
8. The installation should be complete. Please provide SSH login information (IP and password) to @staticfloat for configuration in the buildkite queues.

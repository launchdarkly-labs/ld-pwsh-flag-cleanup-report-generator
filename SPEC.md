Create a powershell script that helps engineering teams with identifying feature flags that should be cleaned up. The script should use ldcli whenever possible. Requests to fetch flags from LD should support pagination and make sure all flags from a given project are evaluated. The script should support the ability to evaluate flags from multiple LD projects. 

The ultimate objective is to use this scrip as part of a PR validation in Github and the output should be a PR comment outlining which flags are ready for code removal and/or archival, grouped by LD projects. 

The script takes input arguments:
- projKey: <string>, project key of the LD project from which the flags should be fetched
- envKey: <string>, environment key of the environment that should be considered for things such as flag statuses, flag evaluation data, whether flag serves as a prerequisite

The script creates ldcli commands to fetch flags that are:
- Ready for code removal
- Ready for archival

To determine which flags are ready for code removal, the following filters should be applied:
- (if enabled) The flag type is 'temporary'
- Flag is older than ${daysSinceCreation}
- (if enabled) Flag has one or more code references
- (if enabled) The flag status is 'launched'
<!-- - (if enabled) The flag is not used as a prerequisite for other flags -->

To determin which flags are ready for archival, the following filters should be applied:
- (if enabled) The flag type is 'temporary'
- Flag is older than ${daysSinceCreation}
- Flag was not evaluated after now-${daysSinceLastEvaluation}
- (if enabled) Flag has no code references
- (if enabled) The flag status is 'inactive'
<!-- - (if enabled) The flag is not used as a prerequisite for other flags -->

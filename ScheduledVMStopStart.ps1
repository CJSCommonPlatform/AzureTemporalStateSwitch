workflow ScheduledVMStopStart {
    param(
          [parameter(Mandatory=$true)] [string]$SubscriptionName
        , [bool]$Simulate = $true
        , [bool]$WeekendOperation = $false
        , [int]$Delay = 180
    )

    # get current time and adjust for GMT/BST
    $gmtInfo = [TimeZoneInfo]::FindSystemTimeZoneById('GMT Standard Time')
    $currentTime = ( Get-Date ).ToUniversalTime()
    $currentTime = $currentTime.Add($gmtInfo.GetUtcOffset($currentTime))

    # obtain list of weekdays to check for weekend operation
    $weekdays = @(
        [System.DayOfWeek]::Monday,
        [System.DayOfWeek]::Tuesday,
        [System.DayOfWeek]::Wednesday,
        [System.DayOfWeek]::Thursday,
        [System.DayOfWeek]::Friday
    )

    # Details for email submission of report
    $Subject = "ScheduledVMStopStart report for $SubscriptionName"
    $Recipient = 'CJSCPOperationalServices@HMCTS.NET'
    $AllRecipients = @( $Recipient, 'stuart.shelton@hmcts.net', 'raj.tiwari@hmcts.net' )
    $Sender ='VM.PowerCycle@HMCTS.NET'
    $SmtpServer = 'HMCTS-NET.mail.protection.outlook.com'
    $Body = @"
<h2>Report for $SubscriptionName run at $currentTime</h2>
$( if ($Simulate) { '<p>Running in simulation mode</p>' } else { '' } )
$( if ($WeekendOperation) { '<p>VMs will be started at weekends</p>' } else { '<p>VMs will be deallocated at weekends</p>' } )
"@

    write-output "Report for $SubscriptionName run at $currentTime"

    # The name of the Automation Credential Asset this runbook will use to authenticate to Azure
    $CredentialAssetName = 'VM-PowerCycle'

    # Get the credential with the above name from the Automation Asset store
    $Cred = Get-AutomationPSCredential -Name $CredentialAssetName
    if( ! $Cred ) {
        Throw "Could not find an Automation Credential Asset named '${CredentialAssetName}'. Make sure you have created one in this Automation Account."
        # Unreachable?
        return $false
    }

    # Connect to Azure Account
    $Account = Add-AzureRmAccount -Credential $Cred
    if( ! $Account ) {
        Throw "Could not authenticate to Azure using the credential asset '${CredentialAssetName}'. Make sure the user name and password are correct."
        # Unreachable?
        return $false
    }

    Set-AzureRmContext -SubscriptionName $SubscriptionName

    $taggedResourceGroups = Get-AzureRmResourceGroup | where { $_.Tags -and $_.Tags.ContainsKey( 'AutoShutdownSchedule' ) }
    $vmList = @(
        Get-AzureRmVM |
        Where-Object { ( $_.Tags -and $_.Tags.ContainsKey( 'AutoShutdownSchedule' ) ) -or $taggedResourceGroups.ResourceGroupName -contains $_.ResourceGroupName } |
        Sort-Object -Property @{ Expression={ if ( $_.Tags -and $_.Tags[ 'ShutdownOrder' ] ) { $_.Tags[ 'ShutdownOrder' ] } else { 0 } } }
    )

    $shutdownList = @()
    $startupList = @()

    foreach( $vm in $vmList ) {
        $schedule = $null

        if( $vm.Tags -and $vm.Tags[ 'ShutdownOrder' ] ) {
            Add-Member -InputObject $vm -NotePropertyName ShutdownOrder -NotePropertyValue $vm.Tags[ 'ShutdownOrder' ]
        } else {
            Add-Member -InputObject $vm -NotePropertyName ShutdownOrder -NotePropertyValue "0"
        }

        # Check for direct tag or group-inherited tag
        if( $vm.Tags -and $vm.Tags.ContainsKey( 'AutoShutdownSchedule' ) ) {
            # VM has direct tag (possible for resource manager deployment model VMs). Prefer this tag schedule
            $schedule = $vm.Tags[ 'AutoShutdownSchedule' ]

            Write-Output "[$( $vm.Name ) order:$( $vm.ShutdownOrder )]: Tagged with schedule $schedule"
        } elseif( $taggedResourceGroups.ResourceGroupName -contains $vm.ResourceGroupName ) {
            # VM belongs to a tagged resource group. Use the group tag
            $parentGroup = $taggedResourceGroups | where ResourceGroupName -eq $vm.ResourceGroupName
            $schedule = $parentGroup.Tags[ 'AutoShutdownSchedule' ]
            Write-Output "[$( $vm.Name ) order:$( $vm.ShutdownOrder )]: In resource group with schedule $schedule"
        }

        # Check that tag value was succesfully obtained
        if( $schedule -eq $null ) {
            Write-Output "[$( $vm.Name ) order:$( $vm.ShutdownOrder )]: Failed to get schedule, skipping this VM."
        } else {
            # Parse the ranges in the Tag value. Expects a string of comma-separated time ranges, or a single time range
            $timeRangeList = @( $schedule -split "," | foreach { $_.Trim() } )

            # Check each range against the current time to see if any schedule is matched
            $scheduleMatched = $false
            $matchedSchedule = $null
            $found = $false

            foreach( $entry in $timeRangeList ) {
                $result = CheckScheduleEntry -TimeRange $entry -CurrentTime $currentTime

                if( -not $found -and $result ) {
                    $scheduleMatched = $true
                    $matchedSchedule = $entry
                    $found = $true
                }
            }

            # Add the VM to the correct list - either shutdown or startup
            if( $scheduleMatched ) {
                # Schedule is matched. Add to shutdown list
                $shutdownList += $vm
            } else {
                # Schedule not matched. Add to startup list
                $startupList = @( $vm ) + $startupList
            }
        }
    }

    # Always process the shutdown list
    if( $shutdownList.Count -gt 0 ) {
        $Body += "<p>Ensuring the following VMs are deallocated:</p><pre>"
        Write-Output "Processing shutdown list"
        $shutdownTiers = $shutdownList.ShutdownOrder | Sort-Object | Get-Unique
        foreach( $tier in $shutdownTiers ) {
            $Body += "  ShutdownOrder $tier`r`n"
            write-output "  Tier $tier"

            foreach -parallel ( $vm in $shutdownList | where ShutdownOrder -eq $tier ) {
                if( $Simulate ) {
                    write-output "    [$( [System.Math]::Round((date -UFormat %s),0) )] Simulating stop for $( $vm.Name )"
                } else {
                    write-output "    [$( [System.Math]::Round((date -UFormat %s),0) )] Stopping $( $vm.Name )"
                    $stopResult = $vm | Stop-AzureRmVM -Force -ErrorAction SilentlyContinue
                }

                $workflow:Body += "    [$( [System.Math]::Round((date -UFormat %s),0) )] Stopping $( $vm.Name )`r`n"             
            }

            $Body += "`r`n"

            Start-Sleep -s $Delay
       }
    }

    # Check the weekend operation flag to determine if the startup list should be processed
    if ($WeekendOperation -or $weekdays.Contains($currentTime.DayOfWeek)) {
        if( $startupList.Count -gt 0 ) {
            $Body += "<p>Ensuring the following VMs are running:</p><pre>"
            Write-Output "Processing startup list"
            $startupTiers = $startupList.ShutdownOrder | Sort-Object -Descending | Get-Unique
            foreach( $tier in $startupTiers ) {
                $Body += "  Tier $tier`r`n"
                write-output "  Tier $tier"

                foreach -parallel ( $vm in $startupList | where ShutdownOrder -eq $tier ) {
                    if( $Simulate ) {
                        write-output "    [$( [System.Math]::Round((date -UFormat %s),0) )] Simulating start for $( $vm.Name )"
                    } else {
                        write-output "    [$( [System.Math]::Round((date -UFormat %s),0) )] Starting $( $vm.Name )"
                        $startResult = $vm | Start-AzureRmVM -ErrorAction SilentlyContinue
                    }

                    $workflow:Body += "    [$( [System.Math]::Round((date -UFormat %s),0) )] Starting $( $vm.Name )`r`n"
                }

                $Body += "`r`n"

                Start-Sleep -s $Delay
            }
        }
    }

    Send-MailMessage `
        -To $AllRecipients `
        -Subject $Subject  `
        -Body $Body `
        -UseSsl `
        -Port 25 `
        -SmtpServer $SmtpServer `
        -From $Sender `
        -BodyAsHtml
    
    function CheckScheduleEntry {
        param(
              [parameter(Mandatory=$true)] [String]$TimeRange
            , [parameter(Mandatory=$true)] [DateTime]$CurrentTime = (( Get-Date ).ToUniversalTime()).Add($gmtInfo.GetUtcOffset(( Get-Date ).ToUniversalTime()))
        )

        # Initialize variables
        $rangeStart, $rangeEnd, $parsedDay = $null
        $midnight = $CurrentTime.AddDays( 1 ).Date

        try {
            # Parse as range if contains '->'
            if( $TimeRange -like "*->*" ) {
                $timeRangeComponents = $TimeRange -split "->" | foreach { $_.Trim() }
                if( $timeRangeComponents.Count -eq 2 ) {
                    $rangeStart = Get-Date $timeRangeComponents[0]
                    $rangeEnd = Get-Date $timeRangeComponents[1]

                    # Check for crossing midnight
                    if( $rangeStart -gt $rangeEnd ) {
                        # If current time is between the start of range and midnight tonight, interpret start time as earlier today and end time as tomorrow
                        if( $CurrentTime -ge $rangeStart -and $CurrentTime -lt $midnight ) {
                            $rangeEnd = $rangeEnd.AddDays( 1 )
                        } else {
                            # Otherwise interpret start time as yesterday and end time as today
                            $rangeStart = $rangeStart.AddDays( -1 )
                        }
                    }
                } else {
                    Write-Output "`tWARNING: Invalid time range format. Expects valid .Net DateTime-formatted start time and end time separated by '->'"
                }
            } else {
                # Otherwise attempt to parse as a full day entry, e.g. 'Monday' or 'December 25'
                if( [ System.DayOfWeek ].GetEnumValues() -contains $TimeRange ) {
                    # If specified as day of week, check if today
                    if( $TimeRange -eq ( Get-Date ).DayOfWeek ) {
                        $parsedDay = Get-Date "00:00"
                    } else {
                        # Skip detected day of week that isn't today
                    }
                } else {
                    # Otherwise attempt to parse as a date, e.g. 'December 25'
                    $parsedDay = Get-Date $TimeRange
                }

                if( $parsedDay -ne $null ) {
                    $rangeStart = $parsedDay # Defaults to midnight
                    $rangeEnd = $parsedDay.AddHours( 23 ).AddMinutes( 59 ).AddSeconds( 59 ) # End of the same day
                }
            }
        }
        catch {
            Write-Output "`tWARNING: Exception encountered while parsing time range. Details: $($_.Exception.Message). Check the syntax of entry, e.g. '<StartTime> -> <EndTime>', or days/dates like 'Sunday' and 'December 25'"   
            return $false
        }

        return ( $CurrentTime -ge $rangeStart -and $CurrentTime -le $rangeEnd )
    }
}

#EOF
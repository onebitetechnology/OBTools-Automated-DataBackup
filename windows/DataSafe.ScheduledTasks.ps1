function New-DataSafeCatchUpLogonTrigger([string]$TaskUser) {
  if ([string]::IsNullOrWhiteSpace($TaskUser)) {
    throw "DataSafe could not determine the signed-in Windows user for the catch-up task."
  }

  return New-ScheduledTaskTrigger -AtLogOn -User $TaskUser
}

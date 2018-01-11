Source-Control for Microsoft Azure Runbooks
===========================================

Currently, GitHub configuration (... and only GitHub is offered) for applying
the principles of source-control to Azure runbooks (which are otherwise
uncontrolled, with no abillity to track/audit change) is in a very preliminary
state: setup is largely manual and somewhat fragile.

GitHub repos must be authenticated by links to specific user accounts, there is
currently no facility to use a service-principal or application-password.

The 'Source Control' option from the 'Automation Accounts' blade is potentially
misleading - although this can be manually executed, this is not the intended
usage.  Actually, the GitHub 'Repository Synchronization' item exists in order
to review the logs to confirm that a push to GitHub has occurred and succeeded.

Instead, one must navigate to 'Automation Accounts' -> account -> [Process
Automation] 'Runbooks' -> runbook, then choose "Edit" from the top menu.  From
here, there should now be a new 'Check in' item besides a GitHub logo, which
will trigger the platform's GitHub Bot to trigger the Source Control script to
push changes to GitHub.

It does not appear to be possible to alter the GitHub parameters (path, branch,
etc.) without disconnecting the service first...

$xdoc = [xml] (get-content ".\settings.xml")

$postgresLocation = $xdoc.restorebackup.settings.postgresql.path
$backupLocation = $xdoc.restorebackup.settings.backuplocation
$username = $xdoc.restorebackup.settings.postgresql.username
$password = $xdoc.restorebackup.settings.postgresql.password
$groupRole = $xdoc.restorebackup.settings.postgresql.grouprole

$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Mendix-Username", $xdoc.restorebackup.settings.mendix.username)
$headers.Add("Mendix-ApiKey", $xdoc.restorebackup.settings.mendix.apikey)
$headers.Add("Accept", "application/json")

if ($password -ne $null) {
    $env:PGPASSWORD = $password
}

Foreach ($database in $xdoc.restorebackup.databases.database) {

    $appid = $database.appid
    $environment = $database.environment
    $databaseName = $database.target
    $display = "$appid ($environment)"
    $preservelocalbackup = $database.preservelocalbackup

    Write-Output "$display - Querying available snapshots."
    $snapshots = Invoke-RestMethod -Method Get -Headers $headers -Uri "https://deploy.mendix.com/api/1/apps/$appid/environments/$environment/snapshots" -Verbose

    # obtain the first snapshot which is completed
    $snapshot = $null
    Foreach ($s in $snapshots) {
        if ($s.State = 'Completed') {
            $snapshot = $s
            break
        }
    }

    if ($snapshot -eq $null) {
        Write-Error "$display - No suitable snapshot found."
        continue
    }

    $snapshotid = $snapshot.SnapshotID
    $snapshotcreated = [timezone]::CurrentTimeZone.ToLocalTime(([datetime]'1/1/1970').AddSeconds($snapshot.CreatedOn / 1000))
    $download = Invoke-RestMethod -Method Get -Headers $headers -Uri "https://deploy.mendix.com/api/1/apps/$appid/environments/$environment/snapshots/$snapshotid" -Verbose
    $url = $download.DatabaseOnly
    Write-Output "$display - Found snaphot ($($snapshot.SnapshotID)) created at $snapshotcreated with URL $url"
    $backup = $backupLocation + "\downloads\" + $database.appid + "-" + $database.environment + "-" + $snapshot.SnapshotID

    Write-Output "$display - Downloading database backup as $backup"
    $webclient = New-Object -TypeName System.Net.WebClient
    $webclient.DownloadFile($url, $backup)
    Write-Output "$display - Backup downloaded"
    
    
    $cmdPath = Join-Path -path (get-item env:\windir).value -ChildPath system32

    if (!(Test-Path $backup)) {
        Write-Error "$display - Downloaded backup not found!"
        continue
    }

    if ($preservelocalbackup -eq "true") {
        Write-Output "$display - Creating backup of current database"
        $dateTime = Get-Date -format "yyyyMMddHHmm"
        
        $backupOldDatabase = $backupLocation + "\" + $dateTime + "-" + $database.appid + ".gz"

        $res = &"$postgresLocation\bin\pg_dump.exe" --no-owner --file=$backupOldDatabase --compress=9 --host=127.0.0.1 --username=$username $databaseName 
 
        Write-Output "$display - Old database stored in $backupOldDatabase"
    }

    Write-Output "$display - Terminating open connections to database"
    $sql = "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();"
    $res = &"$postgresLocation\bin\psql.exe" -d $databaseName --host=127.0.0.1 --username=$username -c `"$sql`"

    Write-Output "$display - Dropping database"
    $res = &"$postgresLocation\bin\psql.exe" --host=127.0.0.1 --username=$username -c `"DROP DATABASE $databaseName`"

    Write-Output "$display - Creating database"
    $sql = "CREATE DATABASE $databaseName WITH ENCODING='UTF8' CONNECTION LIMIT=-1;"
    $res = &"$postgresLocation\bin\psql.exe" --host=127.0.0.1 --username=$username -c `"$sql`"

    Write-Output "$display - Restoring new database ($backup)"
    $res = &"$postgresLocation\bin\pg_restore.exe" -d $databaseName --no-tablespaces --no-owner --no-privileges --host=127.0.0.1 --jobs=3 --username=$username $backup 2>&1

    echo $res

    if ($groupRole -ne $null -And $groupRole -ne "") {
        Write-Output "$display - Setting permissions"
        $res = &"$postgresLocation\bin\psql.exe" -d $databaseName --host=127.0.0.1 --username=$username -c `"GRANT ALL ON DATABASE \`"$databaseName\`" TO GROUP $groupRole`"
    }

    Write-Output "$display - Cleaning up download"
    Remove-Item -Recurse -Force $backup

    Foreach ($script in $database.postscripts.script) {
        Write-Output "$display - Executing post restore script $script"
        $res = &"$postgresLocation\bin\psql.exe" -d $databaseName --host=127.0.0.1 --username=$username -f $script
    }

    Write-Output "$display - Done"
}

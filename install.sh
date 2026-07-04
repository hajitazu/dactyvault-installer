#!/bin/bash

# =========================================================================
# DactyVault One-Click Automatic Installer Script (Official GitHub Release)
# =========================================================================

# 1. Pastikan dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31m[ERROR] Silakan jalankan skrip ini sebagai root (sudo bash)!\e[0m"
    exit 1
fi

echo -e "\e[34m==================================================\e[0m"
echo -e "\e[32m       STARTING DACTYVAULT AUTO INSTALLER        \e[0m"
echo -e "\e[34m==================================================\e[0m"

# 2. Buat direktori struktur yang dibutuhkan
echo -e "\e[33m[1/5] Membuat struktur direktori...\e[0m"
mkdir -p /var/www/pterodactyl/storage/dactyvault
mkdir -p /var/www/pterodactyl/storage/rclone
chown -R www-data:www-data /var/www/pterodactyl/storage/dactyvault
chown -R www-data:www-data /var/www/pterodactyl/storage/rclone

# 3. Inject Core Engine Script (Bash Script + Auto Purge 7 Days)
echo -e "\e[33m[2/5] Memasang Core Backup Engine (Bash)...\e[0m"
cat << 'EOF' > /var/www/pterodactyl/storage/dactyvault_backup.sh
#!/bin/bash
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"

for i in "$@"
do
case $i in
    --remote=*) REMOTE="${i#*=}" ; shift ;;
    --folder=*) FOLDER="${i#*=}" ; shift ;;
    --servers=*) SERVERS_INPUT="${i#*=}" ; shift ;;
esac
done

if [ -z "$REMOTE" ] || [ -z "$SERVERS_INPUT" ]; then
    echo "[ERROR] Parameter --remote atau --servers kosong!"
    exit 1
fi

TEMP_BACKUP_DIR="/tmp/dactyvault_cache"
mkdir -p $TEMP_BACKUP_DIR

IFS=',' read -r -a SERVER_ARRAY <<< "$SERVERS_INPUT"
CLEAN_FOLDER=$(echo "$FOLDER" | sed 's/^\///' | sed 's/\/$//')

for SERVER_UUID in "${SERVER_ARRAY[@]}"
do
    SERVER_DIR="/var/lib/pterodactyl/volumes/$SERVER_UUID"
    if [ -d "$SERVER_DIR" ]; then
        DATE_STR=$(date +"%d-%m-%Y_%I-%M-%p")
        BACKUP_FILENAME="(${DATE_STR})_${SERVER_UUID}.tar.gz"
        LOCAL_ZIP_PATH="$TEMP_BACKUP_DIR/$BACKUP_FILENAME"
        
        echo "[INFO] Mengompres volume data untuk server: $SERVER_UUID"
        tar -czf "$LOCAL_ZIP_PATH" -C "$SERVER_DIR" .
        
        if [ -z "$CLEAN_FOLDER" ]; then
            TARGET_REMOTE_PATH="${REMOTE}:${BACKUP_FILENAME}"
            CLOUD_PURGE_DIR="${REMOTE}:"
        else
            TARGET_REMOTE_PATH="${REMOTE}:${CLEAN_FOLDER}/${BACKUP_FILENAME}"
            CLOUD_PURGE_DIR="${REMOTE}:${CLEAN_FOLDER}"
        fi
        
        echo "[INFO] Mengunggah $BACKUP_FILENAME ke cloud storage..."
        rclone copyto "$LOCAL_ZIP_PATH" "$TARGET_REMOTE_PATH" --config "$RCLONE_CONFIG"
        rm -f "$LOCAL_ZIP_PATH"
        echo "[SUCCESS] Server $SERVER_UUID berhasil di-backup."
        
        echo "[INFO] Memeriksa berkas cadangan usang (> 7 hari) untuk server ini di cloud..."
        rclone delete "$CLOUD_PURGE_DIR" --config "$RCLONE_CONFIG" --include "*_${SERVER_UUID}.tar.gz" --min-age 7d --rmdirs
        echo "[INFO] Pembersihan otomatis berkas usang selesai."
    else
        echo "[WARNING] Folder direktori server $SERVER_UUID tidak ditemukan!"
    fi
done
rm -rf $TEMP_BACKUP_DIR
EOF

# Terapkan Permission Aman untuk Core Engine
chmod +x /var/www/pterodactyl/storage/dactyvault_backup.sh
chown root:root /var/www/pterodactyl/storage/dactyvault_backup.sh


# 4. Inject Backend Controller (PHP Laravel)
echo -e "\e[33m[3/5] Menyuntikkan Backend Controller (PHP)...\e[0m"
cat << 'EOF' > /var/www/pterodactyl/app/Http/Controllers/Admin/DactyVaultController.php
<?php
namespace Pterodactyl\Http\Controllers\Admin;
use Illuminate\Http\Request;
use Illuminate\View\View;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\RedirectResponse;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Models\Server;
use Prologue\Alerts\AlertsMessageBag;

class DactyVaultController extends Controller {
    protected $alert;
    protected $cronLocalPath = '/var/www/pterodactyl/storage/dactyvault/cron.txt';
    protected $rcloneConfig = '/var/www/pterodactyl/storage/rclone/rclone.conf';

    public function __construct(AlertsMessageBag $alert) { $this->alert = $alert; }

    public function index(): View {
        $remotes = []; $rclonePath = trim(shell_exec('which rclone'));
        if (!empty($rclonePath) && file_exists($this->rcloneConfig)) {
            $command = $rclonePath . " listremotes --config {$this->rcloneConfig} 2>&1";
            $output = shell_exec($command);
            if (!empty($output) && strpos($output, 'failed') === false) {
                $rawRemotes = array_filter(explode("\n", trim($output)));
                foreach ($rawRemotes as $remote) { $remotes[] = rtrim(trim($remote), ':'); }
            }
        }
        $servers = Server::all(); $cronjobs = [];
        if (file_exists($this->cronLocalPath) && is_readable($this->cronLocalPath)) {
            $currentCron = file_get_contents($this->cronLocalPath);
            if (!empty($currentCron)) {
                $lines = explode("\n", trim($currentCron));
                foreach ($lines as $line) {
                    if (strpos($line, '#') === 0 || empty($line)) continue;
                    $parts = preg_split('/\s+/', $line, 7);
                    if (count($parts) === 7) {
                        $cronjobs[] = [
                            'minute' => $parts[0], 'hour' => $parts[1], 'day_of_month' => $parts[2],
                            'month' => $parts[3], 'day_of_week' => $parts[4], 'user' => $parts[5], 'command' => $parts[6]
                        ];
                    }
                }
            }
        }
        return view('admin.dactyvault.index', compact('remotes', 'servers', 'cronjobs'));
    }

    public function getFolders(Request $request): JsonResponse {
        $remote = $request->get('remote'); $folders = [];
        if (empty($remote)) return response()->json(['folders' => []]);
        $rclonePath = trim(shell_exec('which rclone'));
        if (!empty($rclonePath) && file_exists($this->rcloneConfig)) {
            $command = $rclonePath . " lsf {$remote}: --dirs-only --config {$this->rcloneConfig} 2>&1";
            $output = shell_exec($command);
            if (!empty($output) && strpos($output, 'Failed') === false) {
                $lines = array_filter(explode("\n", trim($output)));
                foreach ($lines as $line) {
                    $cleanName = rtrim(trim($line), '/');
                    if (!empty($cleanName)) $folders[] = $cleanName;
                }
                sort($folders);
            }
        }
        return response()->json(['folders' => array_values($folders)]);
    }

    public function update(Request $request): RedirectResponse {
        $request->validate([
            'rclone_remote' => 'required|string', 'server_ids' => 'required|array',
            'backup_interval' => 'required|integer|min:1|max:24', 'destination_folder' => 'nullable|string',
        ]);
        $interval = $request->input('backup_interval'); $remote = $request->input('rclone_remote');
        $folder = $request->input('destination_folder') ?? '/'; $targetServers = implode(',', $request->input('server_ids'));
        $backupScript = "/var/www/pterodactyl/storage/dactyvault_backup.sh"; 
        $cronJobRule = "0 */{$interval} * * * root /bin/bash {$backupScript} --remote=\"{$remote}\" --folder=\"{$folder}\" --servers=\"{$targetServers}\" > /dev/null 2>&1";
        $cleanCronLines = ["# DactyVault Automated Backup System Configurations"];
        if (file_exists($this->cronLocalPath) && is_readable($this->cronLocalPath)) {
            $currentContent = file_get_contents($this->cronLocalPath);
            $lines = explode("\n", trim($currentContent));
            foreach ($lines as $line) {
                if (strpos($line, 'dactyvault_backup.sh') === false && strpos($line, '#') !== 0 && !empty($line)) {
                    $cleanCronLines[] = $line;
                }
            }
        }
        $cleanCronLines[] = $cronJobRule;
        file_put_contents($this->cronLocalPath, implode("\n", $cleanCronLines) . "\n");
        $this->alert->success('DactyVault automation parameters updated successfully.')->flash();
        return redirect()->route('admin.dactyvault.settings');
    }

    public function deleteCron(Request $request): RedirectResponse {
        $targetIndex = $request->input('cron_index');
        if (file_exists($this->cronLocalPath) && is_readable($this->cronLocalPath)) {
            $currentContent = file_get_contents($this->cronLocalPath);
            $lines = explode("\n", trim($currentContent));
            $dactyLinesCount = 0; $updatedCronLines = ["# DactyVault Automated Backup System Configurations"];
            foreach ($lines as $line) {
                if (empty($line) || strpos($line, '#') === 0) continue;
                if (strpos($line, 'dactyvault_backup.sh') !== false) {
                    if ($dactyLinesCount === (int)$targetIndex) { $dactyLinesCount++; continue; }
                    $dactyLinesCount++;
                }
                $updatedCronLines[] = $line;
            }
            file_put_contents($this->cronLocalPath, implode("\n", $updatedCronLines) . "\n");
            $this->alert->success('The selected automatic backup task has been purged from system engine.')->flash();
        }
        return redirect()->route('admin.dactyvault.settings');
    }
}
EOF

# Terapkan Permission File Controller agar bisa dieksekusi Nginx (www-data)
chmod 644 /var/www/pterodactyl/app/Http/Controllers/Admin/DactyVaultController.php
chown www-data:www-data /var/www/pterodactyl/app/Http/Controllers/Admin/DactyVaultController.php


# 5. Inject Frontend Blade UI View
echo -e "\e[33m[4/5] Menyuntikkan Frontend Tampilan (Blade UI)...\e[0m"
cat << 'EOF' > /var/www/pterodactyl/resources/views/admin/dactyvault/index.blade.php
@extends('layouts.admin')
@section('title') DactyVault Settings @endsection
@section('header-scripts')
    @parent
    <link href="https://cdn.jsdelivr.net/npm/tom-select@2.2.2/dist/css/tom-select.bootstrap3.min.css" rel="stylesheet">
    <style>
        .ts-wrapper.multi .ts-control > div { background: #3c8dbc; color: #fff; border-radius: 3px; padding: 2px 6px; margin: 2px; }
        .ts-wrapper .items-placeholder { color: #999; }
        .ts-wrapper .ts-control > input { display: none !important; }
        .ts-dropdown { display: none !important; }
        .ts-wrapper.multi .ts-control { cursor: pointer; padding: 5px 10px !important; min-height: 34px; background-color: #fff; border: 1px solid #ccc !important; box-shadow: none; }
    </style>
@endsection
@section('content-header')
    <h1>Dacty Vault<small>Configure your cloud backup automation.</small></h1>
@endsection
@section('content')
<form id="backupConfigForm" action="{{ route('admin.dactyvault.settings') }}" method="POST">
    @csrf
    <div class="row">
        <div class="col-xs-12">
            <div class="box box-primary">
                <div class="box-header with-border"><h3 class="box-title">Account Setting</h3></div>
                <div class="box-body">
                    <div class="row">
                        <div class="form-group col-md-4">
                            <label class="control-label">Rclone Storage Account</label>
                            <select name="rclone_remote" id="rclone_remote" class="form-control">
                                @if(empty($remotes)) <option value="">No Account Detected</option>
                                @else <option value="">-- Select Remote Account --</option>
                                    @foreach($remotes as $remote) <option value="{{ $remote }}">{{ $remote }}</option> @endforeach
                                @endif
                            </select>
                        </div>
                    </div>
                </div>
            </div>
            <div class="box box-primary">
                <div class="box-header with-border"><h3 class="box-title">Backup Setting</h3></div>
                <div class="box-body">
                    <div class="row">
                        <div class="form-group col-md-4">
                            <label class="control-label">Target Servers</label>
                            <select name="server_ids[]" id="select-servers" class="form-control" multiple placeholder="Select Servers...">
                                @foreach($servers as $server) <option value="{{ $server->uuid }}">{{ $server->name }} ({{ $server->uuidShort }})</option> @endforeach
                            </select>
                        </div>
                        <div class="form-group col-md-4">
                            <label class="control-label">Backup Interval</label>
                            <select name="backup_interval" id="backup_interval" class="form-control">
                                @for($i = 1; $i <= 24; $i++) <option value="{{ $i }}" {{ $i == 12 ? 'selected' : '' }}>Every {{ $i }} Hour{{ $i > 1 ? 's' : '' }}</option> @endfor
                            </select>
                        </div>
                        <div class="form-group col-md-4">
                            <label class="control-label">Destination Folder</label>
                            <select name="destination_folder" id="destination_folder" class="form-control"><option value="">-- Select Remote First --</option></select>
                        </div>
                    </div>
                </div>
                <div class="box-footer with-border"><button type="button" id="btnSubmitConfig" class="btn btn-primary btn-sm pull-right">Save Settings</button></div>
            </div>
            <div class="box box-info">
                <div class="box-header with-border"><h3 class="box-title">Active Cronjob Automations</h3></div>
                <div class="box-body table-responsive no-padding">
                    <table class="table table-hover">
                        <thead><tr><th>Minute</th><th>Hour</th><th>Day of Month</th><th>Month</th><th>Day of Week</th><th>User</th><th>Target Command / Execution Rule</th><th class="text-center">Action</th></tr></thead>
                        <tbody>
                            @if(empty($cronjobs)) <tr><td colspan="8" class="text-center text-muted">No active DactyVault cronjob automations found.</td></tr>
                            @else
                                @foreach($cronjobs as $index => $cron)
                                    <tr>
                                        <td><code>{{ $cron['minute'] }}</code></td><td><code>{{ $cron['hour'] }}</code></td><td><code>{{ $cron['day_of_month'] }}</code></td><td><code>{{ $cron['month'] }}</code></td><td><code>{{ $cron['day_of_week'] }}</code></td><td><span class="label label-warning">{{ $cron['user'] }}</span></td><td><small><code>{{ $cron['command'] }}</code></small></td>
                                        <td class="text-center"><button type="button" class="btn btn-danger btn-xs trigger-delete-cron" data-id="{{ $index }}" data-rule="{{ $cron['minute'] }} {{ $cron['hour'] }} {{ $cron['day_of_month'] }} {{ $cron['month'] }} {{ $cron['day_of_week'] }}" data-cmd="{{ $cron['command'] }}"><i class="fa fa-trash"></i> Delete Cronjob</button></td>
                                    </tr>
                                @endforeach
                            @endif
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>
</form>

<div class="modal fade" id="confirmSaveModal" tabindex="-1" role="dialog">
    <div class="modal-dialog" role="document">
        <div class="modal-content">
            <div class="modal-header"><h4 class="modal-title text-primary"><i class="fa fa-save"></i> Confirm Backup Automation Schedule</h4></div>
            <div class="modal-body">
                <p>Are you sure you want to schedule this automated task profile into the system crontab?</p>
                <div class="well well-sm">
                    <strong>Backup Interval:</strong> Every <span id="conf_interval" class="text-bold text-blue"></span> Hour(s)<br>
                    <strong>Rclone Account Profile:</strong> <span id="conf_account" class="text-bold text-blue"></span><br>
                    <strong>Destination Remote Directory:</strong> <code id="conf_folder"></code>
                </div>
            </div>
            <div class="modal-footer"><button type="button" class="btn btn-default btn-sm" data-dismiss="modal">Cancel</button><button type="button" id="executeSubmit" class="btn btn-primary btn-sm">Confirm & Save</button></div>
        </div>
    </div>
</div>

<div class="modal fade" id="deleteCronModal" tabindex="-1" role="dialog">
    <div class="modal-dialog" role="document">
        <form action="{{ route('admin.dactyvault.cron.delete') }}" method="POST">
            @csrf
            <input type="hidden" name="cron_index" id="modal_cron_index">
            <div class="modal-content">
                <div class="modal-header"><h4 class="modal-title text-danger"><i class="fa fa-exclamation-triangle"></i> Confirm Cronjob Deletion</h4></div>
                <div class="modal-body">
                    <p>Are you sure you want to delete this specific automated backup task?</p>
                    <div class="well well-sm"><strong>Schedule Rule:</strong> <span id="modal_cron_rule" class="text-blue"></span><br><strong>Command Parameters:</strong> <small><code id="modal_cron_cmd"></code></small></div>
                </div>
                <div class="modal-footer"><button type="button" class="btn btn-default btn-sm" data-dismiss="modal">Cancel</button><button type="submit" class="btn btn-danger btn-sm">Yes, Delete Cronjob</button></div>
            </div>
        </form>
    </div>
</div>
@endsection
@section('footer-scripts')
    @parent
    <script src="https://cdn.jsdelivr.net/npm/tom-select@2.2.2/dist/js/tom-select.complete.min.js"></script>
    <script>
        $(document).ready(function() {
            var serverSelect = new TomSelect('#select-servers', { plugins: ['remove_button'], maxItems: null, persist: false, create: false, controlInput: null });
            $('#rclone_remote').on('change', function() {
                var remoteName = $(this).val(); var folderSelect = $('#destination_folder');
                if (!remoteName) { folderSelect.html('<option value="">-- Select Remote First --</option>'); return; }
                folderSelect.html('<option value="">Loading directories...</option>');
                $.ajax({
                    url: '{{ route("admin.dactyvault.folders") }}', type: 'GET', data: { remote: remoteName },
                    success: function(data) {
                        folderSelect.html('<option value="/">/ (Root Directory)</option>');
                        if (data.folders && data.folders.length > 0) {
                            $.each(data.folders, function(index, folder) { folderSelect.append('<option value="' + folder + '">' + folder + '</option>'); });
                        }
                    },
                    error: function() { folderSelect.html('<option value="">Error fetching folders</option>'); }
                });
            });
            $('#btnSubmitConfig').on('click', function() {
                var interval = $('#backup_interval').val(); var account = $('#rclone_remote').val(); var folder = $('#destination_folder').val() || '/';
                if(!account) { alert('Please select a valid Rclone remote storage account first.'); return; }
                $('#conf_interval').text(interval); $('#conf_account').text(account); $('#conf_folder').text(folder); $('#confirmSaveModal').modal('show');
            });
            $('#executeSubmit').on('click', function() { $('#backupConfigForm').submit(); });
            $('.trigger-delete-cron').on('click', function() {
                var index = $(this).data('id'); var rule = $(this).data('rule'); var cmd = $(this).data('cmd');
                $('#modal_cron_index').val(index); $('#modal_cron_rule').text(rule); $('#modal_cron_cmd').text(cmd); $('#deleteCronModal').modal('show');
            });
        });
    </script>
@endsection
EOF

# Terapkan Permission File View agar bisa dibaca Web Server Nginx (www-data)
chmod 644 /var/www/pterodactyl/resources/views/admin/dactyvault/index.blade.php
chown www-data:www-data /var/www/pterodactyl/resources/views/admin/dactyvault/index.blade.php


# 6. Pasang Engine Sinkronisasi Cronjob Jembatan di VPS Linux
echo -e "\e[33m[5/5] Mengonfigurasi Otomasi Jembatan Sistem Cronjob Linux Engine...\e[0m"
echo "* * * * * root cp /var/www/pterodactyl/storage/dactyvault/cron.txt /etc/cron.d/dactyvault && chmod 644 /etc/cron.d/dactyvault" > /etc/cron.d/dactyvault_sync
chmod 644 /etc/cron.d/dactyvault_sync

# 7. Finishing (Clear Cache Laravel agar langsung update)
echo -e "\e[33m[OPTIMASI] Membersihkan cache template views & routes Laravel Pterodactyl...\e[0m"
cd /var/www/pterodactyl
php artisan view:clear
php artisan route:clear

echo -e "\e[34m==================================================\e[0m"
echo -e "\e[32m  DACTYVAULT SYSTEM INSTALLED SUCCESSFULLY 100%!  \e[0m"
echo -e "\e[34m==================================================\e[0m"

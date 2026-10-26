[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$MessageFile)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'TiboWatch.Core.psm1') -Force -DisableNameChecking
$event=Get-Content -LiteralPath $MessageFile -Raw -Encoding UTF8|ConvertFrom-Json
$null=New-TiboToastXml $event
if(!(Get-TiboField $event 'Sticky') -or [string]$event.Tag -cnotmatch '^(?:[a-f0-9]{16}|tibotest)$'){throw 'Invalid persistent popup payload.'}
$mutex=New-Object Threading.Mutex($false,('Local\TiboResetWatch.Popup.'+$event.Tag))
$owned=$false;$form=$null;$ackFile=$MessageFile+'.shown.json'
try{
    try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(!$owned){exit 0}
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System.Windows.Forms;
public class TiboNotificationForm : Form {
 protected override bool ShowWithoutActivation { get { return true; } }
 protected override CreateParams CreateParams { get { var p=base.CreateParams; p.ExStyle|=0x08000000; return p; } }
}
'@
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object TiboNotificationForm
    $form.Text='Tibo 额度提醒';$form.ClientSize=New-Object Drawing.Size 440,300
    $form.FormBorderStyle=[Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox=$false;$form.MinimizeBox=$false;$form.TopMost=$true
    $form.StartPosition=[Windows.Forms.FormStartPosition]::Manual
    $area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location=New-Object Drawing.Point ([Math]::Max($area.Left,$area.Right-460)),([Math]::Max($area.Top,$area.Bottom-340))
    $form.Font=New-Object Drawing.Font 'Microsoft YaHei UI',10
    $form.BackColor=[Drawing.Color]::White
    $title=New-Object Windows.Forms.Label
    $title.Text=[string]$event.Title;$title.SetBounds(16,14,408,48)
    $title.Font=New-Object Drawing.Font 'Microsoft YaHei UI',11,([Drawing.FontStyle]::Bold)
    $form.Controls.Add($title)
    $body=New-Object Windows.Forms.TextBox
    $body.Multiline=$true;$body.ReadOnly=$true;$body.ScrollBars=[Windows.Forms.ScrollBars]::Vertical
    $body.SetBounds(16,68,408,138);$body.BorderStyle=[Windows.Forms.BorderStyle]::FixedSingle
    $body.BackColor=[Drawing.Color]::White
    $body.Text=[string]$event.Text+[Environment]::NewLine+[Environment]::NewLine+'主帖：'+[string](Get-TiboField $event 'RootText')
    $form.Controls.Add($body)
    $footer=New-Object Windows.Forms.Label
    $published=([datetimeoffset]::Parse([string]$event.At)).ToOffset([timespan]::FromHours(8)).ToString('MM-dd HH:mm')
    $footer.SetBounds(16,212,408,32);$footer.Text="北京时间 $published · 来源 FxEmbed`n关键词线索，不代表个人额度到账"
    $footer.ForeColor=[Drawing.Color]::DimGray;$form.Controls.Add($footer)
    $post=New-Object Windows.Forms.Button;$post.Text='打开本条';$post.SetBounds(16,252,110,32)
    $post.Add_Click({[Diagnostics.Process]::Start([string]$event.Url)|Out-Null});$form.Controls.Add($post)
    $parent=New-Object Windows.Forms.Button;$parent.Text='查看主帖';$parent.SetBounds(138,252,110,32)
    $rootUrl=[string](Get-TiboField $event 'RootUrl');if(!$rootUrl){$rootUrl=[string]$event.Url}
    $parent.Add_Click({[Diagnostics.Process]::Start($rootUrl)|Out-Null});$form.Controls.Add($parent)
    $close=New-Object Windows.Forms.Button;$close.Text='知道了';$close.SetBounds(314,252,110,32)
    $close.Add_Click({$form.Close()});$form.Controls.Add($close)
    $form.Add_Shown({
        $process=[Diagnostics.Process]::GetCurrentProcess()
        $ack=@{ProcessId=$PID;StartTicks=$process.StartTime.ToUniversalTime().Ticks;WindowHandle=$form.Handle.ToInt64();Tag=[string]$event.Tag}
        [IO.File]::WriteAllText($ackFile,($ack|ConvertTo-Json),(New-Object Text.UTF8Encoding $false))
    })
    $form.Add_FormClosed({param($sender,$closeEventArgs)
        if([string]$closeEventArgs.CloseReason -eq 'UserClosing'){
            $receipt=@{Closed=$true;Key=[string]$event.Key;Tag=[string]$event.Tag;At=[datetimeoffset]::UtcNow.ToString('o')}
            [IO.File]::WriteAllText(($MessageFile+'.closed.json'),($receipt|ConvertTo-Json),(New-Object Text.UTF8Encoding $false))
        }
    })
    [Windows.Forms.Application]::Run($form)
}finally{
    if($form){$form.Dispose()}
    if($owned){$mutex.ReleaseMutex();$mutex.Dispose();if(Test-Path -LiteralPath $ackFile){Remove-Item -LiteralPath $ackFile -Force};if(Test-Path -LiteralPath $MessageFile){Remove-Item -LiteralPath $MessageFile -Force}}
}

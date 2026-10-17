# Automatic Sign-In

For PCs you reach only through RustDesk: after a restart they sign in by themselves, so the
keyboard/mouse program and your apps start.

## Turning it on

Installer > *Automatic sign-in* page, or Desk Console > **Automatic sign-in...** on that PC
(asks for admin once; the window stays usable and shows the result when the admin step ends).

- **Existing account** -- e.g. your own. A local account is just its name (`Bob`, also `.\Bob`
  or `PCNAME\Bob`); a domain account is `DOMAIN\user`. The installer checks the password with
  Windows on that page, before anything runs.
- **Dedicated local account** -- just a name (default `BuildRunner`). Created as a **standard
  user** with a non-expiring password if it does not exist. If it exists and the password you typed
  is its current one, nothing is reset. Only when the password does not match is it reset -- which
  loses that account's saved passwords and encrypted files, so setup says so -- and setup refuses to
  reset the account you are signed in with, or an administrator. Keeps your own password off the PC.
- **Lock the screen right after** (recommended) -- a logon task locks the screen 20 s after an
  automatic sign-in: when Windows started less than 3 minutes before, or when someone signed out in
  the last 3 minutes (Windows signs straight back in after a sign-out). A manual sign-in later on is
  left alone. RustDesk and Deskflow keep working at the lock screen.
- **Fast Startup is turned off** while the lock is on. With Fast Startup, *Shut down* + power on is
  a resume, not a start, so "Windows started 3 minutes ago" was never true and the screen stayed
  unlocked. Setup remembers the old setting and puts it back when the lock, or automatic sign-in,
  is turned off.

## How the password is kept

- Stored in the **LSA secret `DefaultPassword`** -- the method Sysinternals Autologon uses --
  never in the plain-text `Winlogon\DefaultPassword` registry value.
- Checked with Windows (`LogonUser`) **before** anything changes: a typo changes nothing.
- **Any administrator of that PC can read it back** (as with Autologon: an LSA secret is protected
  from users, not from admins or SYSTEM). Setup warns when the account is a local administrator, a
  domain account or a Microsoft account: do not use a password you use anywhere else.
- *Only allow Windows Hello sign-in* hides automatic sign-in; setup turns it off, remembers
  the old value, and restores it when automatic sign-in is turned off.
- A new dedicated account's first sign-in would stop on the privacy-settings screen; setup
  sets the policy that skips it.
- Setup records the account it set up (`HKLM\SOFTWARE\DeskConsole\AutoLogonUser`). Windows rewrites
  the name it signs in with whenever another account signs in at the keyboard; the next restart then
  stops at the sign-in screen. Desk Console shows *Windows now names X: re-apply* when the two
  differ -- turn automatic sign-in on again on that PC.

The lock task runs `powershell.exe -EncodedCommand ...` with no script file, so there is nothing
in a folder to delete or edit. On a PC with Microsoft Defender's *attack surface reduction* rules
turned on (they are off by default; an employer or a security baseline sets them), the rule that
blocks obfuscated scripts can stop it, and the screen then stays unlocked after an automatic
sign-in. Look in Event Viewer > Applications and Services Logs > Microsoft > Windows > Windows
Defender > Operational for event 1121 (blocked) or 1122 (audited) at sign-in time.

## Repairing it

*Repair / update this PC* (or any re-run of setup) re-applies the lock task in its current form,
the Fast Startup setting and the recorded account on a PC that already signs in by itself -- no
password needed. PCs set up before 1.7.0 get the new lock check that way.

## Turning it off

Desk Console > **Automatic sign-in... > Turn off**, or the installer's *Turn off*. Removes the
LSA secret, the lock task and the recorded account, and restores the Windows Hello and Fast Startup
settings.

## When it does not sign in

- **A sign-in notice is set** (`LegalNoticeCaption` / `LegalNoticeText` policy, often from an
  employer or a security baseline): Windows shows it and waits for OK before signing in. Desk
  Console keeps it -- it is someone's policy -- and shows *sign-in notice: click OK after a restart
  (RustDesk works there)*: connect with RustDesk after a restart and click OK.
- **Domain policy** may forbid automatic sign-in on domain-joined PCs.
- **Another account signed in at the keyboard** since: see *Windows now names X* above.

## Trade-off

Anyone at the PC after a restart gets that account's desktop until the screen locks. Use the
lock option, prefer a dedicated standard account on PCs you do not sit at, and keep those PCs
somewhere you trust.

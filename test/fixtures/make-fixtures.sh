#!/bin/sh
# make-fixtures.sh DIR: create fake source volumes under DIR (xp, win7, linux, camera) for the
# scanner and copy tests. Deterministic: file sizes come from a seeded LCG, contents from the
# file's own path, mtimes from a fixed epoch, so counts, bytes and md5s are stable.
# Prints "EXPECT <key> <files> <bytes>" lines for the groups the tests check, plus the total.
# Needs GNU coreutils touch (-d @N); runs in the test container (test/Dockerfile.client).
set -eu

OUT=${1:?usage: make-fixtures.sh DIR}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
TALLY=$OUT/.tally
: >"$TALLY"
TAB=$(printf '\t')
SEED=20071012
T0=1186000000

rnd() { # rnd MAX: next pseudo random number in [0, MAX)
	SEED=$(((SEED * 1103515245 + 12345) % 2147483648))
	RND=$((SEED / 65536 % $1))
}

# mk VOLUME/PATH SIZE KIND [KEY...]: create a file of SIZE bytes. KIND jpeg writes JPEG
# magic bytes and an EOI marker, other kinds plain filler. Every KEY gets the file tallied.
mk() {
	_p=$OUT/$1 _s=$2 _k=$3
	shift 3
	mkdir -p "$(dirname "$_p")"
	if [ "$_k" = jpeg ] && [ "$_s" -ge 24 ]; then
		{
			printf '\377\330\377\340\000\020JFIF\000\001\001\000\000\001\000\001\000\000'
			yes "$_p" | head -c $((_s - 22))
			printf '\377\331'
		} >"$_p"
	else
		yes "$_p" | head -c "$_s" >"$_p"
	fi
	rnd 86400
	touch -d "@$((T0 + RND * 37))" "$_p"
	for _key in "$@"; do
		printf '%s\t%s\n' "$_key" "$_s" >>"$TALLY"
	done
}

# photos VOLUME/DIR N PREFIX EXT KEY...: N jpegs of 10..500 KB.
photos() {
	_d=$1 _n=$2 _pre=$3 _ext=$4
	shift 4
	_i=1
	while [ "$_i" -le "$_n" ]; do
		rnd 491520
		mk "$_d/$_pre$(printf '%04d' "$_i").$_ext" $((10240 + RND)) jpeg "$@"
		_i=$((_i + 1))
	done
}

# small VOLUME/PATH KEY...: a 1..20 KB plain file.
small() {
	_f=$1
	shift
	rnd 19456
	mk "$_f" $((1024 + RND)) plain "$@"
}

# ------------------------------------------------------------------ xp (Windows XP, NTFS)
P="xp/Documents and Settings/Jóska"
for f in "levél anyának.doc" "költségvetés 2007.xls" "önéletrajz.rtf" "jegyzet.txt" "-vázlat.txt"; do
	small "$P/My Documents/$f" xp_mydocs
done
photos "$P/My Documents/My Pictures" 12 "DSC" jpg xp_mydocs
photos "$P/My Documents/My Pictures/Nyaralás" 4 "kép" jpg xp_mydocs
small "$P/My Documents/My Pictures/desktop.ini" xp_mydocs
for f in "Kossuth Lajos.mp3" "Nótás.mp3" "02 - track.wma"; do
	small "$P/My Documents/My Music/$f" xp_mydocs
done
small "$P/My Documents/My Videos/esküvő.avi" xp_mydocs
small "$P/Desktop/Jegyzetek.txt" xp_desktop
small "$P/Desktop/Internet Explorer.lnk" xp_desktop
photos "$P/Desktop" 1 "háttér" jpg xp_desktop
for f in "Google.url" "Index.url" "Links/Hotmail.url" "MSN.url"; do
	small "$P/Favorites/$f" xp_favorites
done
OE="$P/Local Settings/Application Data/Identities/{3F2A1B4C-1111-2222-3333-444455556666}/Microsoft/Outlook Express"
for f in Inbox.dbx "Sent Items.dbx" Folders.dbx Offline.dbx "Deleted Items.dbx"; do
	rnd 200000
	mk "$OE/$f" $((4096 + RND)) plain xp_oe
done
mk "$P/Local Settings/Application Data/Microsoft/Outlook/outlook.pst" 271360 plain xp_pst
small "$P/Local Settings/Application Data/Microsoft/Outlook/extend.dat"
small "$P/Application Data/Microsoft/Address Book/Jóska.wab" xp_wab
small "$P/Application Data/Microsoft/Internet Explorer/brndlog.txt"
small "$P/Local Settings/Temp/~DF1234.tmp"
photos "$P/Local Settings/Temporary Internet Files/Content.IE5/ABCD1234" 3 "banner" jpg
mk "$P/NTUSER.DAT" 262144 plain
small "xp/Documents and Settings/All Users/Documents/közös lista.doc" xp_shared
small "xp/Documents and Settings/All Users/Application Data/Microsoft/x.txt"
small "xp/Documents and Settings/Default User/NTUSER.DAT"
small "xp/Documents and Settings/LocalService/NTUSER.DAT"
small "xp/Documents and Settings/NetworkService/Local Settings/Application Data/x.txt"
for f in system32/kernel32.dll system32/drivers/etc/hosts Help/windows.txt Media/chimes.wav; do
	small "xp/WINDOWS/$f"
done
photos "xp/WINDOWS/Web/Wallpaper" 5 "Bliss" jpg
photos "xp/Program Files/Common Files/Microsoft Shared/Clipart" 4 "clip" jpg
small "xp/Program Files/Outlook Express/msimn.exe"
small "xp/Program Files/Outlook Express/readme.txt"
photos "xp/RECYCLER/S-1-5-21-1111-2222-3333-1003" 2 "Dc" jpg
small "xp/System Volume Information/_restore{AB12}/RP1/change.log"
photos "xp/Fotók 2007" 40 "IMG_" jpg xp_fotok
photos "xp/Fotók 2007/Balaton" 20 "IMG_B" JPG xp_fotok
for f in "ajánlat.docx" "számla 001.xls" "számla 002.xls" "szerződés.pdf" "napló.txt" \
	"bemutató.ppt" "levél.rtf" "árlista.csv" "-kezdő.txt"; do
	small "xp/Munka/$f" xp_munka
done
for f in "jelentés Q1.doc" "jelentés Q2.doc" "jelentés Q3.doc" "jelentés Q4.doc"; do
	small "xp/Munka/2006/$f" xp_munka
done
small "xp/Munka/jelentés${TAB}vázlat.doc"
mk "xp/pagefile.sys" 65536 plain
mk "xp/hiberfil.sys" 65536 plain
small "xp/boot.ini"
small "xp/olvass el.txt"

# ------------------------------------------------------------------ win7 (Windows 7, NTFS)
P="win7/Users/Anna"
for f in "Szakdolgozat.docx" "Recept.doc" "Bevásárlás.xlsx" "Útlevél.pdf" "Jegyzetek.txt" "CV.odt"; do
	small "$P/Documents/$f" w7_docs
done
mk "$P/Documents/Outlook Files/x.pst" 307200 plain w7_docs w7_pst
photos "$P/Pictures" 10 "P10" jpg w7_pics
photos "$P/Pictures/Screenshots" 2 "Képernyő" png w7_pics
small "$P/Videos/születésnap.mp4" w7_videos
small "$P/Videos/ballagás.mp4" w7_videos
small "$P/Downloads/menetrend.pdf" w7_downloads
small "$P/Downloads/setup.zip" w7_downloads
small "$P/Desktop/teendők.txt" w7_desktop
WLM="$P/AppData/Local/Microsoft/Windows Live Mail"
small "$WLM/account{A1B2C3D4-0000-1111-2222-333344445555}.oeaccount" w7_wlm
for i in 1 2 3 4 5; do
	small "$WLM/Gmail (anna)/Inbox/levél$i.eml" w7_wlm
done
TB="$P/AppData/Roaming/Thunderbird/Profiles/abcd.default"
small "$TB/prefs.js" w7_tb
small "$TB/ImapMail/imap.gmail.com/INBOX" w7_tb
small "$TB/ImapMail/imap.gmail.com/INBOX.msf" w7_tb
small "$TB/Mail/Local Folders/Inbox" w7_tb
small "$TB/Mail/Local Folders/Inbox.msf" w7_tb
mk "$P/AppData/Local/Microsoft/Outlook/Anna & Béla.pst" 20480 plain w7_pst2
small "$P/AppData/Local/Temp/xyz.tmp"
photos "$P/AppData/Local/Microsoft/Windows/Temporary Internet Files/Low/Content.IE5/X1" 2 "ad" jpg
mk "$P/NTUSER.DAT" 262144 plain
ln -s Documents "$OUT/$P/My Documents"
small "win7/Users/Public/Documents/közös.docx" w7_public
photos "win7/Users/Public/Pictures/Sample Pictures" 2 "Tulipán" jpg w7_public
small "win7/Users/Default/NTUSER.DAT"
ln -s ../ProgramData "$OUT/win7/Users/All Users"
ln -s Users "$OUT/win7/Documents and Settings"
small "win7/Users/desktop.ini"
for f in System32/kernel32.dll Web/Wallpaper/Windows/img0.jpg Help/x.txt; do
	small "win7/Windows/$f"
done
photos "win7/Program Files/Windows Photo Viewer" 3 "sample" jpg
small "win7/ProgramData/Microsoft/x.txt"
photos "win7/\$Recycle.Bin/S-1-5-21-1-2-3-1001" 2 "\$R" jpg
for f in "régi levél.doc" "adóbevallás 2008.pdf" "telefonszámok.txt" "lakás.xls"; do
	small "win7/Windows.old/Users/Old/Documents/$f" w7_old_docs
done
small "win7/Windows.old/Windows/System32/x.dll"
photos "win7/Windows.old/Windows/Web" 2 "wall" jpg
small "win7/Windows.old/Program Files/App/readme.txt"
small "win7/Windows/System32/config/SYSTEM"

# ------------------------------------------------------------------ linux (ext3)
P=linux/home/milan
printf 'NAME="Debian GNU/Linux"\nVERSION="5.0 (lenny)"\nID=debian\n' >"$OUT/linux.os-release"
mkdir -p "$OUT/linux/etc"
mv "$OUT/linux.os-release" "$OUT/linux/etc/os-release"
printf 'milan-pc\n' >"$OUT/linux/etc/hostname"
photos "$P/Pictures" 6 "IMG_" jpg l_pics
photos "$P/Pictures/2008 Hortobágy" 4 "hb" jpg l_pics
for f in "szakdoga.odt" "költség.ods" "notes.txt" "report: final?.txt" "talk.pdf"; do
	small "$P/Documents/$f" l_docs
done
small "$P/Documents/drafts./idea.txt" l_docs
small "$P/Documents/back\\slash & co.txt" l_docs
small "$P/.thunderbird/xyz.default/prefs.js" l_tb
small "$P/.thunderbird/xyz.default/Mail/Local Folders/Inbox" l_tb
small "$P/.thunderbird/xyz.default/Mail/Local Folders/Inbox.msf" l_tb
for f in cur/1199999999.M1P1.milan-pc:2,S cur/1199999998.M2P2.milan-pc:2,S \
	cur/1199999997.M3P3.milan-pc:2,RS new/1199999996.M4P4.milan-pc; do
	small "$P/Maildir/$f" l_maildir
done
mkdir -p "$OUT/$P/Maildir/tmp"
small "$P/.mozilla/firefox/abc123.default/places.sqlite" l_ff
small "$P/.mozilla/firefox/abc123.default/cache2/entries/ABCDEF"
small "$P/.cache/thumbnails/normal/x.png"
small "$P/.bashrc"
small "linux/root/.bashrc"
small "linux/var/mail/milan" l_mbox
for f in pixmaps/debian.png pixmaps/gimp.png doc/bash/README.txt; do
	small "linux/usr/share/$f"
done
small "linux/lib/modules/2.6.26/modules.dep"
small "linux/var/cache/apt/pkgcache.bin"
small "linux/srv/zene/Omega - Gyöngyhajú lány.mp3" l_zene
small "linux/srv/zene/Illés - Little Richard.mp3" l_zene
small "linux/srv/zene/borító.jpg" l_zene

# ------------------------------------------------------------------ camera (FAT32 card)
photos "camera/DCIM/100CANON" 40 "IMG_" JPG cam_dcim
for i in 1 2 3; do
	rnd 400000
	mk "camera/DCIM/100CANON/MVI_000$i.MOV" $((100000 + RND)) plain cam_dcim
done
photos "camera/DCIM/101CANON" 10 "IMG_1" JPG cam_dcim
small "camera/MISC/AUTPRINT.MRK"

# ------------------------------------------------------------------ expectations
awk -F '\t' '{ n[$1]++; b[$1] += $2 } END { for (k in n) printf "EXPECT %s %d %d\n", k, n[k], b[k] }' \
	"$TALLY" | LC_ALL=C sort
rm -f "$TALLY"

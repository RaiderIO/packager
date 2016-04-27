#!/bin/bash
#
# This is free and unencumbered software released into the public domain.
#
# Anyone is free to copy, modify, publish, use, compile, sell, or
# distribute this software, either in source code form or as a compiled
# binary, for any purpose, commercial or non-commercial, and by any
# means.
#
# In jurisdictions that recognize copyright laws, the author or authors
# of this software dedicate any and all copyright interest in the
# software to the public domain. We make this dedication for the benefit
# of the public at large and to the detriment of our heirs and
# successors. We intend this dedication to be an overt act of
# relinquishment in perpetuity of all present and future rights to this
# software under copyright law.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
# For more information, please refer to <http://unlicense.org/>
#

# release.sh generates a zippable addon directory from a Git or SVN checkout.

# don't need to run the packager for pull requests
if [ "$TRAVIS_PULL_REQUEST" = "true" ]; then
	echo "Not packaging pull request."
	exit 0
fi
# only want to package master and tags
if [ -n "$TRAVIS" -a "$TRAVIS_BRANCH" != "master" -a -z "$TRAVIS_TAG" ]; then
	echo "Not packaging \`\`${TRAVIS_BRANCH}''."
	exit 0
fi

# Script return code
exit_code=0

# Site URLs, used to find the localization web app.
site_url="http://wow.curseforge.com http://www.wowace.com"

# Game versions for uploading
game_version=
game_version_id=

# Secrets for uploading
cf_token=$CF_API_KEY
wowi_user=$WOWI_USERNAME
wowi_pass=$WOWI_PASSWORD
github_token=$GITHUB_OAUTH

# Variables set via options.
slug=
addonid=
topdir=
releasedir=
overwrite=
nolib=
line_ending=dos
skip_copying=
skip_externals=
skip_localization=
skip_zipfile=
skip_upload=

# Process command-line options
usage() {
	echo "Usage: release.sh [-celzusod] [-p slug] [-w wowi-id] [-r releasedir] [-t topdir] [-g version]" >&2
	echo "  -c               Skip copying files into the package directory." >&2
	echo "  -e               Skip checkout of external repositories." >&2
	echo "  -l               Skip @localization@ keyword replacement." >&2
	echo "  -z               Skip zipfile creation." >&2
	echo "  -u               Use Unix line-endings." >&2
	echo "  -s               Create a stripped-down \`\`nolib'' package." >&2
	echo "  -o               Keep existing package directory, overwriting its contents." >&2
	echo "  -p slug          Set the project slug used on WowAce or CurseForge." >&2
	echo "  -d               Skip uploading to CurseForge." >&2
	echo "  -w wowi-id       Set the addon id used on WoWInterface for uploading." >&2
	echo "  -r releasedir    Set directory containing the package directory. Defaults to \`\`\$topdir/.release''." >&2
	echo "  -t topdir        Set top-level directory of checkout." >&2
	echo "  -g version       Set the game version for uploading to CurseForge and WoWInterface." >&2
}

OPTIND=1
while getopts ":celzusop:dw:r:t:g:" opt; do
	case $opt in
	c)
		# Skip copying files into the package directory.
		skip_copying=true
		;;
	e)
		# Skip checkout of external repositories.
		skip_externals=true
		;;
	l)
		# Skip @localization@ keyword replacement.
		skip_localization=true
		;;
	d)
		# Skip uploading to CurseForge.
		skip_upload=true
		;;
	o)
		# Skip deleting any previous package directory.
		overwrite=true
		;;
	p)
		slug="$OPTARG"
		;;
	w)
		addonid="$OPTARG"
		;;
	r)
		# Set the release directory to a non-default value.
		releasedir="$OPTARG"
		;;
	s)
		# Create a nolib package.
		nolib=true
		skip_externals=true
		;;
	t)
		# Set the top-level directory of the checkout to a non-default value.
		topdir="$OPTARG"
		;;
	u)
		# Skip Unix-to-DOS line-ending translation.
		line_ending=unix
		;;
	z)
		# Skip generating the zipfile.
		skip_zipfile=true
		;;
	g)
		# Set version (x.y.z)
		if [[ "$OPTARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z]?$ ]]; then
			game_version="$OPTARG"
		else
			echo "Invalid argument for option \`\`-v'' ($OPTARG)" >&2
			usage
			exit 1
		fi
		;;
	:)
		echo "Option \`\`-$OPTARG'' requires an argument." >&2
		usage
		exit 1
		;;
	\?)
		if [ "$OPTARG" != "?" -a "$OPTARG" != "h" ]; then
			echo "Unknown option \`\`-$OPTARG''." >&2
		fi
		usage
		exit 1
		;;
	esac
done
shift $((OPTIND - 1))

# Set $topdir to top-level directory of the checkout.
if [ -z "$topdir" ]; then
	dir=$( pwd )
	if [ -d "$dir/.git" -o -d "$dir/.svn" ]; then
		topdir=.
	else
		dir=${dir%/*}
		topdir=..
		while [ -n "$dir" ]; do
			if [ -d "$topdir/.git" -o -d "$topdir/.svn" ]; then
				break
			fi
			dir=${dir%/*}
			topdir="$topdir/.."
		done
		if [ ! -d "$topdir/.git" -a ! -d "$topdir/.svn" ]; then
			echo "No Git or SVN checkout found." >&2
			exit 1
		fi
	fi
fi

# Set $releasedir to the directory which will contain the generated addon zipfile.
if [ -z "$releasedir" ]; then
	releasedir="$topdir/.release"
fi

# Set $basedir to the basename of the checkout directory.
basedir=$( cd "$topdir" && pwd )
case $basedir in
/*/*)
	basedir=${basedir##/*/}
	;;
/*)
	basedir=${basedir##/}
	;;
esac

# Set $repository_type to "git" or "svn".
repository_type=
if [ -d "$topdir/.git" ]; then
	repository_type=git
elif [ -d "$topdir/.svn" ]; then
	repository_type=svn
else
	echo "No Git or SVN checkout found in \`\`$topdir''." >&2
	exit 1
fi

# $releasedir must be an absolute path or relative to $topdir.
case $releasedir in
/*)			;;
$topdir/*)	;;
*)
	echo "The release directory \`\`$releasedir'' must be an absolute path or relative to \`\`$topdir''." >&2
	exit 1
	;;
esac

# Create the staging directory.
mkdir -p "$releasedir"

# Expand $topdir and $releasedir to their absolute paths for string comparisons later.
topdir=$( cd "$topdir" && pwd )
releasedir=$( cd "$releasedir" && pwd )

###
### set_info_<repo> returns the following information:
###
si_repo_type= # "git" or "svn"
si_repo_dir= # the checkout directory
si_repo_url= # the checkout url
si_tag= # tag for HEAD
si_previous_tag= # previous tag
si_previous_revision= # [SVN] revision number for previous tag

si_project_revision= # [SVN] Turns into the highest revision of the entire project in integer form. e.g. 1234
si_project_hash= # [Git] Turns into the hash of the entire project in hex form. e.g. 106c634df4b3dd4691bf24e148a23e9af35165ea
si_project_abbreviated_hash= # [Git] Turns into the abbreviated hash of the entire project in hex form. e.g. 106c63f
si_project_author= # Turns into the last author of the entire project. e.g. ckknight
si_project_date_iso= # Turns into the last changed date (by UTC) of the entire project in ISO 8601. e.g. 2008-05-01T12:34:56Z
si_project_date_integer= # Turns into the last changed date (by UTC) of the entire project in a readable integer fashion. e.g. 2008050123456
si_project_timestamp= # Turns into the last changed date (by UTC) of the entire project in POSIX timestamp. e.g. 1209663296
si_project_version= # Turns into an approximate version of the project. The tag name if on a tag, otherwise it's up to the repo. SVN returns something like "r1234", Git returns something like "v0.1-873fc1"

si_file_revision= # Turns into the current revision of the file in integer form. e.g. 1234
si_file_hash= # Turns into the hash of the file in hex form. e.g. 106c634df4b3dd4691bf24e148a23e9af35165ea
si_file_abbreviated_hash= # Turns into the abbreviated hash of the file in hex form. e.g. 106c63
si_file_author= # Turns into the last author of the file. e.g. ckknight
si_file_date_iso= # Turns into the last changed date (by UTC) of the file in ISO 8601. e.g. 2008-05-01T12:34:56Z
si_file_date_integer= # Turns into the last changed date (by UTC) of the file in a readable integer fashion. e.g. 20080501123456
si_file_timestamp= # Turns into the last changed date (by UTC) of the file in POSIX timestamp. e.g. 1209663296

set_info_git() {
	si_repo_dir="$1"
	si_repo_type="git"
	_si_git_dir="--git-dir=$si_repo_dir/.git"
	si_repo_url=$( git "$_si_git_dir" remote get-url origin 2>/dev/null | sed -e 's/^git@\(.*\):/https:\/\/\1\//' )
	if [ -z "$si_repo_url" ]; then # no origin so grab the first fetch url
		si_repo_url=$( git "$_si_git_dir" remote -v | grep '(fetch)' | awk '{ print $2; exit }' | sed -e 's/^git@\(.*\):/https:\/\/\1\//' )
	fi

	# Populate filter vars.
	si_project_hash=$( git "$_si_git_dir" show --no-patch --format="%H" 2>/dev/null )
	si_project_abbreviated_hash=$( git "$_si_git_dir" show --no-patch --format="%h" 2>/dev/null )
	si_project_author=$( git "$_si_git_dir" show --no-patch --format="%an" 2>/dev/null )
	si_project_timestamp=$( git "$_si_git_dir" show --no-patch --format="%at" 2>/dev/null )
	si_project_date_iso=$( date -ud "@$si_project_timestamp" -Iseconds 2>/dev/null )
	si_project_date_integer=$( date -ud "@$si_project_timestamp" +%Y%m%d%H%M%S 2>/dev/null )
	# Git repositories have no project revision.
	si_project_revision=

	# Get the tag for the HEAD.
	si_previous_tag=
	si_previous_revision=
	_si_tag=$( git "$_si_git_dir" describe --tags --always 2>/dev/null )
	si_tag=$( git "$_si_git_dir" describe --tags --always --abbrev=0 2>/dev/null )
	# Set $si_project_version to the version number of HEAD. May be empty if there are no commits.
	si_project_version=$si_tag
	# The HEAD is not tagged if the HEAD is several commits past the most recent tag.
	if [ "$si_tag" = "$si_project_hash" ]; then
		# --abbrev=0 expands out the full sha if there was no previous tag
		si_project_version=$_si_tag
		si_previous_tag=
		si_tag=
	elif [ "$_si_tag" != "$si_tag" ]; then
		si_project_version=$_si_tag
		si_previous_tag=$si_tag
		si_tag=
	else # we're on a tag, just jump back one commit
		si_previous_tag=$( git "$_si_git_dir" describe --tags --abbrev=0 HEAD~ 2>/dev/null )
	fi
}

set_info_svn() {
	si_repo_dir="$1"
	si_repo_type="svn"

	# Temporary file to hold results of "svn info".
	_si_svninfo="${si_repo_dir}/.svn/release_sh_svninfo"
	svn info "$si_repo_dir" 2>/dev/null > "$_si_svninfo"

	if [ -s "$_si_svninfo" ]; then
		_si_root=$( awk '/^Repository Root:/ { print $3; exit }' < "$_si_svninfo" )
		_si_url=$( awk '/^URL:/ { print $2; exit }' < "$_si_svninfo" )
		_si_revision=$( awk '/^Last Changed Rev:/ { print $NF; exit }' < "$_si_svninfo" )
		si_repo_url=$_si_root

		case ${_si_url#${_si_root}/} in
		tags/*)
			# Extract the tag from the URL.
			si_tag=${_si_url#${_si_root}/tags/}
			si_tag=${si_tag%%/*}
			si_project_revision="$_si_revision"
			;;
		*)
			# Check if the latest tag matches the working copy revision (/trunk checkout instead of /tags)
			_si_tag_line=$( svn log --verbose --limit 1 "$_si_root/tags" 2>/dev/null | awk '/^   A/ { print $0; exit }' )
			_si_tag=$( echo "$_si_tag_line" | awk '/^   A/ { print $2 }' | awk -F/ '{ print $NF }' )
			_si_tag_from_revision=$( echo "$_si_tag_line" | sed -re "s/^.*:([0-9]+)\).*$/\1/" ) # (from /project/trunk:N)

			if [ "$_si_tag_from_revision" = "$_si_revision" ]; then
				si_tag="$_si_tag"
				si_project_revision=$( svn info "$_si_root/tags/$si_tag" 2>/dev/null | awk '/^Last Changed Rev:/ { print $NF; exit }' )
			else
				# Set $si_project_revision to the highest revision of the project at the checkout path
				si_project_revision=$( svn info --recursive "$si_repo_dir" 2>/dev/null | awk '/^Last Changed Rev:/ { print $NF }' | sort -nr | head -1 )
			fi
			;;
		esac

		if [ -n "$si_tag" ]; then
			si_project_version="$si_tag"
		else
			si_project_version="r$si_project_revision"
		fi

		# Get the previous tag and it's revision
		_si_limit=$((si_project_revision - 1))
		_si_tag=$( svn log --verbose --limit 1 "$_si_root/tags" -r $_si_limit:1 2>/dev/null | awk '/^   A/ { print $0; exit }' | awk '/^   A/ { print $2 }' | awk -F/ '{ print $NF }' )
		if [ -n "$_si_tag" ]; then
			si_previous_tag="$_si_tag"
			si_previous_revision=$( svn info "$_si_root/tags/$_si_tag" 2>/dev/null | awk '/^Last Changed Rev:/ { print $NF; exit }' )
		fi

		# Populate filter vars.
		si_project_author=$( awk '/^Last Changed Author:/ { print $0; exit }' < "$_si_svninfo" | cut -d" " -f4- )
		_si_timestamp=$( awk '/^Last Changed Date:/ { print $4,$5,$6; exit }' < "$_si_svninfo" )
		si_project_timestamp=$( date -ud "$_si_timestamp" +%s 2>/dev/null )
		si_project_date_iso=$( date -ud "$_si_timestamp" -Iseconds 2>/dev/null )
		si_project_date_integer=$( date -ud "$_si_timestamp" +%Y%m%d%H%M%S 2>/dev/null )
		# SVN repositories have no project hash.
		si_project_hash=
		si_project_abbreviated_hash=

		rm -f "$_si_svninfo"
	fi
}

set_info_file() {
	if [ "$si_repo_type" = "git" ]; then
		_si_file=${1#si_repo_dir} # need the path relative to the checkout
		_si_git_dir="--git-dir=$si_repo_dir/.git"
		# Populate filter vars from the last commit the file was included in.
		si_file_hash=$( git "$_si_git_dir" log --max-count=1 --format="%H" "$_si_file" 2>/dev/null )
		si_file_abbreviated_hash=$( git "$_si_git_dir" log --max-count=1  --format="%h"  "$_si_file" 2>/dev/null )
		si_file_author=$( git "$_si_git_dir" log --max-count=1 --format="%an" "$_si_file" 2>/dev/null )
		si_file_timestamp=$( git "$_si_git_dir" log --max-count=1 --format="%at" "$_si_file" 2>/dev/null )
		si_file_date_iso=$( date -ud "@$si_file_timestamp" -Iseconds 2>/dev/null )
		si_file_date_integer=$( date -ud "@$si_file_timestamp" +%Y%m%d%H%M%S 2>/dev/null )
		# Git repositories have no project revision.
		si_file_revision=
	elif [ "$si_repo_type" = "svn" ]; then
		_si_file="$1"
		# Temporary file to hold results of "svn info".
		_sif_svninfo="svninfo"
		svn info "$_si_file" 2>/dev/null > "$_sif_svninfo"
		if [ -s "$_sif_svninfo" ]; then
			# Populate filter vars.
			si_file_revision=$( awk '/^Last Changed Rev:/ { print $NF; exit }' < "$_sif_svninfo" )
			si_file_author=$( awk '/^Last Changed Author:/ { print $0; exit }' < "$_sif_svninfo" | cut -d" " -f4- )
			_si_timestamp=$( awk '/^Last Changed Date:/ { print $4,$5,$6; exit }' < "$_sif_svninfo" )
			si_file_timestamp=$( date -ud "$_si_timestamp" +%s 2>/dev/null )
			si_file_date_iso=$( date -ud "$_si_timestamp" -Iseconds 2>/dev/null )
			si_file_date_integer=$( date -ud "$_si_timestamp" +%Y%m%d%H%M%S 2>/dev/null )
			# SVN repositories have no project hash.
			si_file_hash=
			si_file_abbreviated_hash=

			rm -f "$_sif_svninfo"
		fi
	fi
}

# Set some version info about the project
case $repository_type in
git)	set_info_git "$topdir" ;;
svn)	set_info_svn "$topdir" ;;
esac

tag=$si_tag
project_version=$si_project_version
previous_version=$si_previous_tag
project_hash=$si_project_hash
project_revision=$si_project_revision
previous_revision=$si_previous_revision
project_timestamp=$si_project_timestamp
project_github_url=
project_github_slug=
if [[ "$si_repo_url" == "https://github.com"* ]]; then
	project_github_url=${si_repo_url%.git}
	project_github_slug=${project_github_url#https://github.com/}
fi

# Set the slug for cf/wowace checkouts.
if [ -z "$slug" ] && [[ "$si_repo_url" == *"curseforge.com"* || "$si_repo_url" == *"wowace.com"* ]]; then
	slug=${si_repo_url#*/wow/}
	slug=${slug%%/*}
fi
# The default slug is the lowercase basename of the checkout directory.
if [ -z "$slug" ]; then
	slug=$( echo "$basedir" | tr '[:upper:]' '[:lower:]' )
fi

# Bare carriage-return character.
carriage_return=$( printf "\r" )

# Returns 0 if $1 matches one of the colon-separated patterns in $2.
match_pattern() {
	_mp_file=$1
	_mp_list="$2:"
	while [ -n "$_mp_list" ]; do
		_mp_pattern=${_mp_list%%:*}
		_mp_list=${_mp_list#*:}
		case $_mp_file in
		$_mp_pattern)
			return 0
			;;
		esac
	done
	return 1
}

# Simple .pkgmeta YAML processor.
yaml_keyvalue() {
	yaml_key=${1%%:*}
	yaml_value=${1#$yaml_key:}
	yaml_value=${yaml_value#"${yaml_value%%[! ]*}"} # trim leading whitespace
}

yaml_listitem() {
	yaml_item=${1#-}
	yaml_item=${yaml_item#"${yaml_item%%[! ]*}"} # trim leading whitespace
}

###
### Process .pkgmeta to set variables used later in the script.
###

# Variables set via .pkgmeta.
changelog=
changelog_markup="plain"
enable_nolib_creation=true
ignore=
license=
contents=
nolib_exclude=
package=$basedir

if [ -f "$topdir/.pkgmeta" ]; then
	yaml_eof=
	while [ -z "$yaml_eof" ]; do
		IFS='' read -r yaml_line || yaml_eof=true
		# Strip any trailing CR character.
		yaml_line=${yaml_line%$carriage_return}
		case $yaml_line in
		[!\ ]*:*)
			# Split $yaml_line into a $yaml_key, $yaml_value pair.
			yaml_keyvalue "$yaml_line"
			# Set the $pkgmeta_phase for stateful processing.
			pkgmeta_phase=$yaml_key

			case $yaml_key in
			enable-nolib-creation)
				if [ "$yaml_value" = "no" ]; then
					enable_nolib_creation=
				fi
				;;
			license-output)
				license=$yaml_value
				;;
			manual-changelog)
				changelog=$yaml_value
				;;
			package-as)
				package=$yaml_value
				;;
			esac
			;;
		" "*)
			yaml_line=${yaml_line#"${yaml_line%%[! ]*}"} # trim leading whitespace
			case $yaml_line in
			"- "*)
				# Get the YAML list item.
				yaml_listitem "$yaml_line"
				case $pkgmeta_phase in
				ignore)
					pattern=$yaml_item
					if [ -d "$topdir/$pattern" ]; then
						pattern="$pattern/*"
					fi
					if [ -z "$ignore" ]; then
						ignore="$pattern"
					else
						ignore="$ignore:$pattern"
					fi
					;;
				esac
				;;
			*:*)
				# Split $yaml_line into a $yaml_key, $yaml_value pair.
				yaml_keyvalue "$yaml_line"
				case $pkgmeta_phase in
				manual-changelog)
					case $yaml_key in
					filename)
						changelog=$yaml_value
						;;
					markup-type)
						changelog_markup=$yaml_value
						;;
					esac
					;;
				esac
				;;
			esac
			;;
		esac
	done < "$topdir/.pkgmeta"
fi

echo
echo "Packaging $package ($slug)"
if [ -n "$project_version" ]; then
	echo "Current version: $project_version"
fi
if [ -n "$previous_version" ]; then
	echo "Previous version: $previous_version"
fi

# Set $pkgdir to the path of the package directory inside $releasedir.
pkgdir="$releasedir/$package"
if [ -d "$pkgdir" -a -z "$overwrite" ]; then
	#echo "Removing previous package directory: $pkgdir"
	rm -fr "$pkgdir"
fi
if [ ! -d "$pkgdir" ]; then
	mkdir -p "$pkgdir"
fi

# Set the contents of the addon zipfile.
contents="$package"

###
### Create filters for pass-through processing of files to replace repository keywords.
###

# Filter for simple repository keyword replacement.
simple_filter() {
	sed \
		-e "s/@project-revision@/$si_project_revision/g" \
		-e "s/@project-hash@/$si_project_hash/g" \
		-e "s/@project-abbreviated-hash@/$si_project_abbreviated_hash/g" \
		-e "s/@project-author@/$si_project_author/g" \
		-e "s/@project-date-iso@/$si_project_date_iso/g" \
		-e "s/@project-date-integer@/$si_project_date_integer/g" \
		-e "s/@project-timestamp@/$si_project_timestamp/g" \
		-e "s/@project-version@/$si_project_version/g" \
		-e "s/@file-revision@/$si_file_revision/g" \
		-e "s/@file-hash@/$si_file_hash/g" \
		-e "s/@file-abbreviated-hash@/$si_file_abbreviated_hash/g" \
		-e "s/@file-author@/$si_file_author/g" \
		-e "s/@file-date-iso@/$si_file_date_iso/g" \
		-e "s/@file-date-integer@/$si_file_date_integer/g" \
		-e "s/@file-timestamp@/$si_file_timestamp/g"
}

# Find URL of localization app.
localization_url=
cache_localization_url() {
	localization_url=
	for _ul_site_url in $site_url; do
		_localization_url="${_ul_site_url}/addons/$slug/localization"
		if curl -s -I "$_localization_url/" | grep -q "200 OK"; then
			localization_url=$_localization_url
		fi
	done
}

# Filter to handle @localization@ repository keyword replacement.
localization_filter() {
	_ul_eof=
	while [ -z "$_ul_eof" ]; do
		IFS='' read -r _ul_line || _ul_eof=true
		# Strip any trailing CR character.
		_ul_line=${_ul_line%$carriage_return}
		case $_ul_line in
		*--@localization\(*\)@*)
			_ul_lang=
			_ul_namespace=
			# Get the prefix of the line before the comment.
			_ul_prefix=${_ul_line%%--*}
			# Strip everything but the localization parameters.
			_ul_params=${_ul_line#*@localization(}
			_ul_params=${_ul_params%)@}
			# Sanitize the params a bit. (namespaces are restricted to [a-zA-Z0-9_], separated by [./:])
			_ul_params=${_ul_params// /}
			_ul_params=${_ul_params//,/, }
			# Generate a URL parameter string from the localization parameters.
			set -- ${_ul_params}
			_ul_url_params=
			_ul_skip_fetch=
			for _ul_param; do
				_ul_key=${_ul_param%%=*}
				_ul_value=${_ul_param#*=\"}
				_ul_value=${_ul_value%\"*}
				case ${_ul_key} in
					escape-non-ascii)
						if [ "$_ul_param" = "true" ]; then
							_ul_url_params="${_ul_url_params}&escape_non_ascii=y"
						fi
						;;
					format)
						_ul_url_params="${_ul_url_params}&format=${_ul_value}"
						;;
					handle-unlocalized)
						_ul_url_params="${_ul_url_params}&handle_unlocalized=${_ul_value}"
						;;
					handle-subnamespaces)
						_ul_url_params="${_ul_url_params}&handle_subnamespaces=${_ul_value}"
						;;
					locale)
						_ul_url_params="${_ul_url_params}&language=${_ul_value}"
						_ul_lang=$_ul_value
						;;
					namespace)
						# Verify that the localization namespace is valid.  The CF packager will silently allow
						# and remove @localization@ calls with invalid namespaces.
						_ul_namespace_url=$( echo "${localization_url}/namespaces/${_ul_value}" | tr '[:upper:]' '[:lower:]' )
						if curl -s -I "$_ul_namespace_url/" | grep -q "200 OK"; then
							: "valid namespace"
							_ul_namespace=$_ul_value
						else
							echo "  Invalid localization namespace \`\`$_ul_value''." >&2
							_ul_skip_fetch=true
						fi
						_ul_url_params="${_ul_url_params}&namespace=${_ul_value}"
						;;
				esac
			done
			# Strip any leading or trailing ampersands.
			_ul_url_params=${_ul_url_params#&}
			_ul_url_params=${_ul_url_params%&}
			echo -n "$_ul_prefix"
			if [ -z "$_ul_skip_fetch" ]; then
				if [ -n "$_ul_namespace" ]; then
					echo "  adding $_ul_lang/$_ul_namespace" >&2
				else
					echo "  adding $_ul_lang" >&2
				fi
				# Fetch the localization data, but don't output anything if the namespace was not valid.
				curl -s "${localization_url}/export.txt?${_ul_url_params}" | awk '/namespace.*Not a valid choice/ { skip = 1; next } skip == 1 { next } { print }'
			fi
			# Insert a trailing blank line to match CF packager.
			if [ -z "$_ul_eof" ]; then
				echo ""
			fi
			;;
		*)
			if [ -n "$_ul_eof" ]; then
				echo -n "$_ul_line"
			else
				echo "$_ul_line"
			fi
		esac
	done
}

lua_filter() {
	sed \
		-e "s/--@$1@/--[===[@$1@/g" \
		-e "s/--@end-$1@/--@end-$1@]===]/g" \
		-e "s/--\[===\[@non-$1@/--@non-$1@/g" \
		-e "s/--@end-non-$1@\]===\]/--@end-non-$1@/g"
}

toc_filter() {
	_trf_token=$1; shift
	_trf_comment=
	_trf_eof=
	while [ -z "$_trf_eof" ]; do
		IFS='' read -r _trf_line || _trf_eof=true
		# Strip any trailing CR character.
		_trf_line=${_trf_line%$carriage_return}
		_trf_passthrough=
		case $_trf_line in
		"#@${_trf_token}@"*)
			_trf_comment="# "
			_trf_passthrough=true
			;;
		"#@end-${_trf_token}@"*)
			_trf_comment=
			_trf_passthrough=true
			;;
		esac
		if [ -z "$_trf_passthrough" ]; then
			_trf_line="$_trf_comment$_trf_line"
		fi
		if [ -n "$_trf_eof" ]; then
			echo -n "$_trf_line"
		else
			echo "$_trf_line"
		fi
	done
}

xml_filter() {
	sed \
		-e "s/<!--@$1@-->/<!--@$1/g" \
		-e "s/<!--@end-$1@-->/@end-$1@-->/g" \
		-e "s/<!--@non-$1@/<!--@non-$1@-->/g" \
		-e "s/@end-non-$1@-->/<!--@end-non-$1@-->/g"
}

do_not_package_filter() {
	_dnpf_token=$1; shift
	_dnpf_string="do-not-package"
	_dnpf_start_token=
	_dnpf_end_token=
	case $_dnpf_token in
	lua)
		_dnpf_start_token="--@$_dnpf_string@"
		_dnpf_end_token="--@end-$_dnpf_string@"
		;;
	toc)
		_dnpf_start_token="#@$_dnpf_string@"
		_dnpf_end_token="#@end-$_dnpf_string@"
		;;
	xml)
		_dnpf_start_token="<!--@$_dnpf_string@-->"
		_dnpf_end_token="<!--@end-$_dnpf_string@-->"
		;;
	esac
	if [ -z "$_dnpf_start_token" -o -z "$_dnpf_end_token" ]; then
		cat
	else
		# Replace all content between the start and end tokens, inclusive, with a newline to match CF packager.
		_dnpf_eof=
		_dnpf_skip=
		while [ -z "$_dnpf_eof" ]; do
			IFS='' read -r _dnpf_line || _dnpf_eof=true
			# Strip any trailing CR character.
			_dnpf_line=${_dnpf_line%$carriage_return}
			case $_dnpf_line in
			*$_dnpf_start_token*)
				_dnpf_skip=true
				echo -n "${_dnpf_line%%${_dnpf_start_token}*}"
				;;
			*$_dnpf_end_token*)
				_dnpf_skip=
				if [ -z "$_dnpf_eof" ]; then
					echo ""
				fi
				;;
			*)
				if [ -z "$_dnpf_skip" ]; then
					if [ -n "$_dnpf_eof" ]; then
						echo -n "$_dnpf_line"
					else
						echo "$_dnpf_line"
					fi
				fi
				;;
			esac
		done
	fi
}

line_ending_filter() {
	_lef_eof=
	while [ -z "$_lef_eof" ]; do
		IFS='' read -r _lef_line || _lef_eof=true
		# Strip any trailing CR character.
		_lef_line=${_lef_line%$carriage_return}
		if [ -n "$_lef_eof" ]; then
			# Preserve EOF not preceded by newlines.
			echo -n "$_lef_line"
		else
			case $line_ending in
			dos)
				# Terminate lines with CR LF.
				printf "%s\r\n" "$_lef_line"
				;;
			unix)
				# Terminate lines with LF.
				printf "%s\n" "$_lef_line"
				;;
			esac
		fi
	done
}

###
### Copy files from the working directory into the package directory.
###

# Copy of the contents of the source directory into the destination directory.
# Dotfiles and any files matching the ignore pattern are skipped.  Copied files
# are subject to repository keyword replacement.
#
copy_directory_tree() {
	_cdt_alpha=
	_cdt_debug=
	_cdt_ignored_patterns=
	_cdt_localization=
	_cdt_nolib=
	_cdt_do_not_package=
	_cdt_unchanged_patterns=
	OPTIND=1
	while getopts :adi:lnpu: _cdt_opt "$@"; do
		case $_cdt_opt in
		a)	_cdt_alpha=true ;;
		d)	_cdt_debug=true ;;
		i)	_cdt_ignored_patterns=$OPTARG ;;
		l)	_cdt_localization=true
			cache_localization_url
			;;
		n)	_cdt_nolib=true ;;
		p)	_cdt_do_not_package=true ;;
		u)	_cdt_unchanged_patterns=$OPTARG ;;
		esac
	done
	shift $((OPTIND - 1))
	_cdt_srcdir=$1
	_cdt_destdir=$2

	echo "Copying files from \`\`${_cdt_srcdir#$topdir/}'' into \`\`${_cdt_destdir#$topdir/}'':"
	if [ ! -d "$_cdt_destdir" ]; then
		mkdir -p "$_cdt_destdir"
	fi
	# Create a "find" command to list all of the files in the current directory, minus any ones we need to prune.
	_cdt_find_cmd="find ."
	# Prune everything that begins with a dot except for the current directory ".".
	_cdt_find_cmd="$_cdt_find_cmd \( -name \".*\" -a \! -name \".\" \) -prune"
	# Prune the destination directory if it is a subdirectory of the source directory.
	_cdt_dest_subdir=${_cdt_destdir#${_cdt_srcdir}/}
	case $_cdt_dest_subdir in
	/*)	;;
	*)	_cdt_find_cmd="$_cdt_find_cmd -o -path \"./$_cdt_dest_subdir\" -prune" ;;
	esac
	# Print the filename, but suppress the current directory ".".
	_cdt_find_cmd="$_cdt_find_cmd -o \! -name \".\" -print"
	( cd "$_cdt_srcdir" && eval $_cdt_find_cmd ) | while read file; do
		file=${file#./}
		if [ -f "$_cdt_srcdir/$file" ]; then
			# Check if the file should be ignored.
			skip_copy=
			# Skip files matching the colon-separated "ignored" shell wildcard patterns.
			if [ -z "$skip_copy" ] && match_pattern "$file" "$_cdt_ignored_patterns"; then
				skip_copy=true
			fi
			# Never skip files that match the colon-separated "unchanged" shell wildcard patterns.
			unchanged=
			if [ -n "$skip_copy" ] && match_pattern "$file" "$_cdt_unchanged_patterns"; then
				skip_copy=
				unchanged=true
			fi
			# Copy unskipped files into $_cdt_destdir.
			if [ -n "$skip_copy" ]; then
				echo "Ignoring: $file"
			else
				dir=${file%/*}
				if [ "$dir" != "$file" ]; then
					mkdir -p "$_cdt_destdir/$dir"
				fi
				# Check if the file matches a pattern for keyword replacement.
				skip_filter=true
				if match_pattern "$file" "*.lua:*.md:*.toc:*.txt:*.xml"; then
					skip_filter=
				fi
				if [ -n "$skip_filter" -o -n "$unchanged" ]; then
					echo "Copying: $file (unchanged)"
					cp "$_cdt_srcdir/$file" "$_cdt_destdir/$dir"
				else
					# Set the filter for @localization@ replacement.
					_cdt_localization_filter=cat
					# XXX should probably kill the build if the file has a locale replacement but the url isn't working
					if [ -n "$_cdt_localization" -a -n "$localization_url" ]; then
						_cdt_localization_filter=localization_filter
					fi
					# Set the alpha, debug, and nolib filters for replacement based on file extension.
					_cdt_alpha_filter=cat
					if [ -n "$_cdt_alpha" ]; then
						case $file in
						*.lua)	_cdt_alpha_filter="lua_filter alpha" ;;
						*.toc)	_cdt_alpha_filter="toc_filter alpha" ;;
						*.xml)	_cdt_alpha_filter="xml_filter alpha" ;;
						esac
					fi
					_cdt_debug_filter=cat
					if [ -n "$_cdt_debug" ]; then
						case $file in
						*.lua)	_cdt_debug_filter="lua_filter debug" ;;
						*.toc)	_cdt_debug_filter="toc_filter debug" ;;
						*.xml)	_cdt_debug_filter="xml_filter debug" ;;
						esac
					fi
					_cdt_nolib_filter=cat
					if [ -n "$_cdt_nolib" ]; then
						case $file in
						*.toc)	_cdt_nolib_filter="toc_filter no-lib-strip" ;;
						*.xml)	_cdt_nolib_filter="xml_filter no-lib-strip" ;;
						esac
					fi
					_cdt_do_not_package_filter=cat
					if [ -n "$_cdt_do_not_package" ]; then
						case $file in
						*.lua)	_cdt_do_not_package_filter="do_not_package_filter lua" ;;
						*.toc)	_cdt_do_not_package_filter="do_not_package_filter toc" ;;
						*.xml)	_cdt_do_not_package_filter="do_not_package_filter xml" ;;
						esac
					fi
					# As a side-effect, files that don't end in a newline silently have one added.
					# POSIX does imply that text files must end in a newline.
					set_info_file "$_cdt_srcdir/$file"
					echo "Copying: $file"
					cat "$_cdt_srcdir/$file" \
						| simple_filter \
						| $_cdt_alpha_filter \
						| $_cdt_debug_filter \
						| $_cdt_nolib_filter \
						| $_cdt_do_not_package_filter \
						| $_cdt_localization_filter \
						| line_ending_filter \
						> "$_cdt_destdir/$file"
				fi
			fi
		fi
	done
}

if [ -z "$skip_copying" ]; then
	echo
	cdt_args="-dp"
	if [ -n "$tag" ]; then
		cdt_args="${cdt_args}a"
	fi
	if [ -z "$skip_localization" ]; then
		cdt_args="${cdt_args}l"
	fi
	if [ -n "$nolib" ]; then
		cdt_args="${cdt_args}n"
	fi
	if [ -n "$ignore" ]; then
		cdt_args="$cdt_args -i \"$ignore\""
	fi
	if [ -n "$changelog" ]; then
		cdt_args="$cdt_args -u \"$changelog\""
	fi
	eval copy_directory_tree $cdt_args "\"$topdir\"" "\"$pkgdir\""
fi

###
### Create a default license if not present and .pkgmeta requests one.
###

if [ -n "$license" -a ! -f "$topdir/$license" ]; then
	echo
	echo "Generating license into $license."
	echo "All Rights Reserved." | line_ending_filter > "$pkgdir/$license"
fi

###
### Process .pkgmeta again to perform any pre-move-folders actions.
###

# Sites that are skipped for checking out externals if creating a "nolib" package.
external_nolib_sites="curseforge.com wowace.com"

# Queue for external checkouts.
external_dir=
external_uri=
external_tag=

queue_external() {
	external_dir=$1
	external_uri=$2
	external_tag=$3
	output_file="$releasedir/.${RANDOM}.externalout"
	checkout_queued_external &> "$output_file"
	cat "$output_file" 2>/dev/null
	rm "$output_file" 2>/dev/null
}

checkout_queued_external() {
	if [ -n "$external_dir" -a -n "$external_uri" -a -z "$skip_externals" ]; then
		# Checkout the external into a ".checkout" subdirectory of the final directory.
		_cqe_checkout_dir="$pkgdir/$external_dir/.checkout"
		mkdir -p "$_cqe_checkout_dir"
		echo
		case $external_uri in
		git:*|http://git*|https://git*)
			if [ -z "$external_tag" ]; then
				echo "Fetching latest version of external $external_uri."
				git clone --depth 1 "$external_uri" "$_cqe_checkout_dir"
			elif [ "$external_tag" != "latest" ]; then
				echo "Fetching tag \`\`$external_tag'' of external $external_uri."
				git clone --depth 1 --branch "$external_tag" "$external_uri" "$_cqe_checkout_dir"
			else
				# Determine the latest tag in a remote Git repository:
				#
				#	1. Clone the last 100 commits from the remote repository.
				#	2. Find the most recent annotated tag.
				#	3. Checkout that tag into the working directory.
				#	4. If no tag is found, then leave the latest commit as the checkout.
				#
				echo "Fetching external $external_uri."
				git clone --depth 100 "$external_uri" "$_cqe_checkout_dir"
				external_tag=$(
					latest_tag=$( git --git-dir="$_cqe_checkout_dir/.git" for-each-ref refs/tags --sort=-taggerdate --format="%(refname)" --count=1 )
					latest_tag=${latest_tag#refs/tags/}
					if [ -n "$latest_tag" ]; then
						echo "$latest_tag"
					else
						echo "latest"
					fi
				)
				if [ "$external_tag" != "latest" ]; then
					echo "Checking out \`\`$external_tag'' into \`\`$_cqe_checkout_dir''."
					( cd "$_cqe_checkout_dir" && git checkout "$external_tag" )
				fi
			fi
			set_info_git "$_cqe_checkout_dir"
			_cqe_external_project_revision=$si_project_revision
			;;
		svn:*|http://svn*|https://svn*)
			if [ -z "$external_tag" ]; then
				echo "Fetching latest version of external $external_uri."
				svn checkout "$external_uri" "$_cqe_checkout_dir"
			else
				case $external_uri in
				*/trunk)
					_cqe_svn_trunk_url=$external_uri
					_cqe_svn_subdir=
					;;
				*)
					_cqe_svn_trunk_url="${external_uri%/trunk/*}/trunk"
					_cqe_svn_subdir=${external_uri#${_cqe_svn_trunk_url}/}
					;;
				esac
				_cqe_svn_tag_url="${_cqe_svn_trunk_url%/trunk}/tags"
				if [ "$external_tag" = "latest" ]; then
					# Determine the latest tag in a SVN repository:
					#
					#	1. Get the last commit in the /tags URL for the SVN repository.
					#	2. Extract the tag for that commit.
					#	3. Checkout that tag into the working directory.
					#	4. If no tag is found, then checkout the latest version.
					#
					external_tag=$(	svn log --verbose --limit 1 "$_cqe_svn_tag_url" 2>/dev/null | awk '/^   A \/tags\// { print $2; exit }' )
					# Strip leading and trailing bits.
					external_tag=${external_tag#/tags/}
					external_tag=${external_tag%%/*}
					if [ -z "$external_tag" ]; then
						external_tag="latest"
					fi
				fi
				if [ "$external_tag" = "latest" ]; then
					echo "No tags found in $_cqe_svn_tag_url."
					echo "Fetching latest version of external $external_uri."
					svn checkout "$external_uri" "$_cqe_checkout_dir"
				else
					_cqe_external_uri="${_cqe_svn_tag_url}/$external_tag"
					if [ -n "$_cqe_svn_subdir" ]; then
						_cqe_external_uri="${_cqe_external_uri}/$_cqe_svn_subdir"
					fi
					echo "Fetching tag \`\`$external_tag'' from external $_cqe_external_uri."
					svn checkout "$_cqe_external_uri" "$_cqe_checkout_dir"
				fi
			fi
			set_info_svn "$_cqe_checkout_dir"
			_cqe_external_project_revision=$si_project_revision
			;;
		*)
			echo "Unknown external: $external_uri" >&2
			;;
		esac
		# Copy the checkout into the proper external directory.
		(
			cd "$_cqe_checkout_dir" || exit
			# Set variables needed for filters.
			project_revision=$_cqe_external_project_revision
			package=${external_dir##*/}
			slug=$( echo "$package" | tr '[:upper:]' '[:lower:]' )
			for _cqe_nolib_site in $external_nolib_sites; do
				case $external_uri in
				*${_cqe_nolib_site}/*)
					# The URI points to a Curse repository.
					slug=${external_uri#*${_cqe_nolib_site}/wow/}
					slug=${slug%%/*}
					break
					;;
				esac
			done
			# If a .pkgmeta file is present, process it for an "ignore" list.
			ignore=
			if [ -f "$_cqe_checkout_dir/.pkgmeta" ]; then
				yaml_eof=
				while [ -z "$yaml_eof" ]; do
					IFS='' read -r yaml_line || yaml_eof=true
					# Strip any trailing CR character.
					yaml_line=${yaml_line%$carriage_return}
					case $yaml_line in
					[!\ ]*:*)
						# Split $yaml_line into a $yaml_key, $yaml_value pair.
						yaml_keyvalue "$yaml_line"
						# Set the $pkgmeta_phase for stateful processing.
						pkgmeta_phase=$yaml_key
						;;
					" "*)
						yaml_line=${yaml_line#"${yaml_line%%[! ]*}"} # trim leading whitespace
						case $yaml_line in
						"- "*)
							# Get the YAML list item.
							yaml_listitem "$yaml_line"
							case $pkgmeta_phase in
							ignore)
								pattern=$yaml_item
								if [ -d "$topdir/$pattern" ]; then
									pattern="$pattern/*"
								fi
								if [ -z "$ignore" ]; then
									ignore="$pattern"
								else
									ignore="$ignore:$pattern"
								fi
								;;
							esac
							;;
						esac
						;;
					esac
				done < "$_cqe_checkout_dir/.pkgmeta"
			fi
			copy_directory_tree -dlnp -i "$ignore" "$_cqe_checkout_dir" "$pkgdir/$external_dir"
		)
		# Remove the ".checkout" subdirectory containing the full checkout.
		if [ -d "$_cqe_checkout_dir" ]; then
			#echo "Removing repository checkout in \`\`$_cqe_checkout_dir''."
			rm -fr "$_cqe_checkout_dir"
		fi
	fi
	# Clear the queue.
	external_dir=
	external_uri=
	external_tag=
}

_external_dir=
_external_uri=
_external_tag=
process_external() {
	if [ -n "$_external_dir" -a -n "$_external_uri" -a -z "$skip_externals" ]; then
		echo "Fetching external: $_external_dir"
		( queue_external "$_external_dir" "$_external_uri" "$_external_tag" ) &
		_external_dir=
		_external_uri=
		_external_tag=
	fi
}

# Don't leave extra files around if exited early
kill_externals() {
	rm -f "$releasedir"/.*.externalout
	kill 0
}
trap kill_externals INT

if [ -f "$topdir/.pkgmeta" ]; then
	yaml_eof=
	while [ -z "$yaml_eof" ]; do
		IFS='' read -r yaml_line || yaml_eof=true
		# Strip any trailing CR character.
		yaml_line=${yaml_line%$carriage_return}
		case $yaml_line in
		[!\ ]*:*)
			# Started a new section, so checkout any queued externals.
			process_external
			# Split $yaml_line into a $yaml_key, $yaml_value pair.
			yaml_keyvalue "$yaml_line"
			# Set the $pkgmeta_phase for stateful processing.
			pkgmeta_phase=$yaml_key
			;;
		" "*)
			yaml_line=${yaml_line#"${yaml_line%%[! ]*}"} # trim leading whitespace
			case $yaml_line in
			"- "*)
				;;
			*:*)
				# Split $yaml_line into a $yaml_key, $yaml_value pair.
				yaml_keyvalue "$yaml_line"
				case $pkgmeta_phase in
				externals)
					case $yaml_key in
					url)
						# Queue external URI for checkout.
						_external_uri=$yaml_value
						;;
					tag)
						# Queue external tag for checkout.
						_external_tag=$yaml_value
						;;
					*)
						# Started a new external, so checkout any queued externals.
						process_external

						_external_dir=$yaml_key
						nolib_exclude="$nolib_exclude $pkgdir/$_external_dir/*"
						if [ -n "$yaml_value" ]; then
							_external_uri=$yaml_value
							# Immediately checkout this fully-specified external.
							process_external
						fi
						;;
					esac
					;;
				esac
				;;
			esac
			;;
		esac
	done < "$topdir/.pkgmeta"
	# Reached end of file, so checkout any remaining queued externals.
	process_external

	if [ -n "$nolib_exclude" ]; then
		echo
		echo "Waiting for externals to finish..."
		wait
	fi
fi
# Restore the signal handlers
trap - INT

###
### Create the changelog of commits since the previous release tag.
###

project="$package"
# Parse the TOC file if it exists for the title of the project.
if [ -f "$topdir/$package.toc" ]; then
	while read toc_line; do
		case $toc_line in
		"## Title: "*)
			project=$( echo ${toc_line#"## Title: "} | sed -e "s/|c[0-9A-Fa-f]\{8\}//g" -e "s/|r//g" )
			;;
		esac
	done < "$topdir/$package.toc"
fi

# Create a changelog in the package directory if the source directory does
# not contain a manual changelog.
if [ -z "$changelog" ]; then
	changelog="CHANGELOG.md"
	changelog_markup="markdown"
fi
if [ ! -f "$topdir/$changelog" -a ! -f "$topdir/CHANGELOG.txt" -a ! -f "$topdir/CHANGELOG.md" ]; then
	echo
	echo "Generating changelog of commits into $changelog"

	if [ "$repository_type" = "git" ]; then
		changelog_url=
		changelog_version=
		git_commit_range=
		if [ -z "$previous_version" -a -z "$tag" ]; then
			# no range, show all commits up to ours
			changelog_url="[Full Changelog](${project_github_url}/commits/$project_hash)"
			changelog_version="[$project_version](${project_github_url}/tree/$project_hash)"
			git_commit_range="$project_hash"
		elif [ -z "$previous_version" -a -n "$tag" ]; then
			# first tag, show all commits upto it
			changelog_url="[Full Changelog](${project_github_url}/commits/$tag)"
			changelog_version="[$project_version](${project_github_url}/tree/$tag)"
			git_commit_range="$tag"
		elif [ -n "$previous_version" -a -z "$tag" ]; then
			# compare between last tag and our commit
			changelog_url="[Full Changelog](${project_github_url}/compare/$previous_version...$project_hash)"
			changelog_version="[$project_version](${project_github_url}/tree/$project_hash)"
			git_commit_range="$previous_version..$project_hash"
		elif [ -n "$previous_version" -a -n "$tag" ]; then
			# compare between last tag and our tag
			changelog_url="[Full Changelog](${project_github_url}/compare/$previous_version...$tag)"
			changelog_version="[$project_version](${project_github_url}/tree/$tag)"
			git_commit_range="$previous_version..$tag"
		fi
		# lazy way out
		if [ -z "$project_github_url" ]; then
			changelog_url=
			changelog_version=$project_version
		fi
		changelog_date=$( date -ud "@$project_timestamp" +%Y-%m-%d )

		cat <<- EOF > "$pkgdir/$changelog"
		# $project

		## $changelog_version ($changelog_date) [](#top)
		$changelog_url

		EOF
		git --git-dir="$topdir/.git" log $git_commit_range --pretty=format:"###   %B" \
			| sed -e "s/^/    /g" -e "s/^ *$//g" -e "s/^    ###/-/g" -e 's/\[ci skip\]//g' -e 's/git-svn-id:.*//g' -e '/^\s*$/d' \
			| line_ending_filter >> "$pkgdir/$changelog"

	elif [ "$repository_type" = "svn" ]; then
		svn_revision_range=
		if [ -n "$previous_version" ]; then
			svn_revision_range="-r$project_revision:$previous_revision"
		fi
		changelog_date=$( date -ud "@$project_timestamp" +%Y-%m-%d )

		cat <<- EOF > "$pkgdir/$changelog"
		# $project

		## $project_version ($changelog_date)

		EOF
		svn log "$topdir" "$svn_revision_range" --xml \
			| awk '/<msg>/,/<\/msg>/' \
			| sed -e 's/<msg>/###   /g' -e 's/<\/msg>//g' -e "s/^/    /g" -e "s/^ *$//g" -e "s/^    ###/-/g" -e 's/\[ci skip\]//g' -e '/^\s*$/d' \
			| line_ending_filter >> "$pkgdir/$changelog"

	fi

	echo
	cat "$pkgdir/$changelog"
fi

###
### Process .pkgmeta to perform move-folders actions.
###

if [ -f "$topdir/.pkgmeta" ]; then
	yaml_eof=
	_mf_found=
	while [ -z "$yaml_eof" ]; do
		IFS='' read -r yaml_line || yaml_eof=true
		# Strip any trailing CR character.
		yaml_line=${yaml_line%$carriage_return}
		case $yaml_line in
		[!\ ]*:*)
			# Split $yaml_line into a $yaml_key, $yaml_value pair.
			yaml_keyvalue "$yaml_line"
			# Set the $pkgmeta_phase for stateful processing.
			pkgmeta_phase=$yaml_key
			;;
		" "*)
			yaml_line=${yaml_line#"${yaml_line%%[! ]*}"} # trim leading whitespace
			case $yaml_line in
			"- "*)
				;;
			*:*)
				# Split $yaml_line into a $yaml_key, $yaml_value pair.
				yaml_keyvalue "$yaml_line"
				case $pkgmeta_phase in
				move-folders)
					srcdir="$releasedir/$yaml_key"
					destdir="$releasedir/$yaml_value"
					if [ -d "$destdir" -a -z "$overwrite" ]; then
						#echo "Removing previous moved folder: $destdir"
						rm -fr "$destdir"
					fi
					if [ -d "$srcdir" ]; then
						if [ -z "$_mf_found" ]; then
							_mf_found=true
							echo
						fi
						if [ ! -d "$destdir" ]; then
							mkdir -p "$destdir"
						fi
						echo "Moving \`\`$yaml_key'' to \`\`$yaml_value''"
						mv -f "$srcdir"/* "$destdir" && rm -fr "$srcdir"
						contents="$contents $yaml_value"
						# Copy the license into $destdir if one doesn't already exist.
						if [ -n "$license" -a -f "$pkgdir/$license" -a ! -f "$destdir/$license" ]; then
							cp -f "$pkgdir/$license" "$destdir/$license"
						fi
					fi
					# update external dir
					nolib_exclude=${nolib_exclude//$srcdir/$destdir}
					;;
				esac
				;;
			esac
			;;
		esac
	done < "$topdir/.pkgmeta"
fi

###
### Create the final zipfile for the addon.
###

if [ -z "$skip_zipfile" ]; then
	archive_version="$project_version"
	archive_name="$package-$project_version.zip"
	archive="$releasedir/$archive_name"

	nolib_archive_version="$project_version-nolib"
	nolib_archive_name="$package-$nolib_archive_version.zip"
	nolib_archive="$releasedir/$nolib_archive_name"

	if [ -n "$nolib" ]; then
		archive_version="$nolib_archive_version"
		archive_name="$nolib_archive_name"
		archive="$nolib_archive"
		nolib_archive=
	fi

	# export the zip file name for other scripts
	export PACKAGER_ARCHIVE=$archive
	export PACKAGER_ARCHIVE_NOLIB=$nolib_archive

	echo
	echo "Creating archive: $archive_name"

	if [ -f "$archive" ]; then
		rm -f "$archive"
	fi
	( cd "$releasedir" && zip -X -r "$archive" $contents )

	if [ ! -f "$archive" ]; then
		exit 1
	fi

	# Create nolib version of the zipfile
	if [ -n "$enable_nolib_creation" -a -z "$nolib" -a -n "$nolib_exclude" ]; then
		echo
		echo "Creating no-lib archive: $nolib_archive_name"

		# run the nolib_filter
		find "$pkgdir" -type f \( -name "*.xml" -o -name "*.toc" \) -print | while read file; do
			case $file in
			*.toc)	_filter="toc_filter no-lib-strip" ;;
			*.xml)	_filter="xml_filter no-lib-strip" ;;
			esac
			$_filter < "$file" > "$file.tmp" && mv "$file.tmp" "$file"
		done

		# make the exclude paths relative to the release directory
		nolib_exclude=${nolib_exclude//$releasedir\//}

		if [ -f "$nolib_archive" ]; then
			rm -f "$nolib_archive"
		fi
		# set noglob so each nolib_exclude path gets quoted instead of expanded
		( set -f; cd "$releasedir" && zip -X -r -q "$nolib_archive" $contents -x $nolib_exclude )

		if [ ! -f "$nolib_archive" ]; then
			exit 1
		fi
	fi

	###
	### Deploy the zipfile.
	###

	upload_curseforge=$( test -z "$skip_upload" -a -n "$slug" -a -n "$cf_token" && echo true )
	upload_wowinterface=$( test -n "$tag" -a -n "$addonid" -a -n "$wowi_user" -a -n "$wowi_pass" && echo true )
	upload_github=$( test -n "$tag" -a -n "$project_github_slug" -a -n "$github_token" && echo true )

	if [ -n "$upload_curseforge" -o -n "$upload_wowinterface" -o -n "$upload_github" ]; then
		# Get game version info from Curse (if we have jq)
		if jq --version &>/dev/null; then
			versions_file=$( realpath --relative-to="$(pwd)" "$releasedir/game-versions.json" ) # abs path segfaults jq.. windows/msys issue?
			curl -s "http://wow.curseforge.com/game-versions.json" > "$versions_file"
			# Make sure we got something sane
			if jq -s '.[] | length' "$versions_file" &>/dev/null; then
				if [ -n "$game_version" ]; then
					game_version_id=$( jq -r 'to_entries[] | select(.value.name == "'$game_version'") | .key' "$versions_file" )
				fi
				# Couldn't find a version that matched, just use the most recent (well, highest index)
				if [ -z "$game_version_id" ]; then
					game_version=$( jq -r 'to_entries | max_by(.key | tonumber) | .value.name' "$versions_file" )
					game_version_id=$( jq -r 'to_entries | max_by(.key | tonumber) | .key' "$versions_file" )
				fi
			fi
			rm "$versions_file"

			# Just check here instead of nesting later
			if [ -z "$game_version" -a -n "$upload_wowinterface" ] || [ -z "$game_version_id" -a -n "$upload_curseforge" ]; then
				echo
				echo "Error fetching game version info from http://wow.curseforge.com/game-versions.json"
				if [ -n "$upload_curseforge" ]; then
					echo
					echo "Skipping upload to CurseForge."
					upload_curseforge=
				fi
				if [ -n "$upload_wowinterface" ]; then
					echo
					echo "Skipping upload to WoWInterface."
					upload_wowinterface=
				fi
				exit_code=1
			fi
		else
			# Warn about bailing because of not having jq
			if [ -n "$upload_curseforge" -a -z "$game_version_id" ]; then
				echo
				echo "Skipping upload to CurseForge. Install \`\`jq'' to allow fetching the current version id from Curse."
				upload_curseforge=
				exit_code=1
			fi
			if [ -n "$upload_wowinterface" -a -z "$game_version" ]; then
				echo
				echo "Skipping upload to WoWInterface. Install \`\`jq'' or set the game version on the command line (-g)"
				upload_wowinterface=
				exit_code=1
			fi
			if [ -n "$upload_github" ]; then
				echo
				echo "Skipping release to GitHub. Install \`\`jq'' to allow parsing responses." # and escaping the changelog
				upload_github=
				exit_code=1
			fi
		fi
	fi

	# Upload to CurseForge.
	if [ -n "$upload_curseforge" ]; then
		url="http://wow.curseforge.com/addons/$slug"
		# If the tag contains only dots and digits and optionally starts with
		# the letter v (such as "v1.2.3" or "v1.23" or "3.2") or contains the
		# word "release", then it is considered a release tag. If the above
		# conditions don't match, it is considered a beta tag. Untagged commits
		# are considered alphas.
		file_type=a
		if [ -n "$tag" ]; then
			if [[ "$tag" =~ ^v?[0-9][0-9.]+$ || "$tag" == *"release"* ]]; then
				file_type=r
			else
				file_type=b
			fi
		fi

		if [ -f "$nolib_archive" ]; then
			echo
			echo "Uploading $nolib_archive_name ($file_type - $game_version_id) to $url"

			resultfile="$releasedir/cfresult" # json response
			result=$( curl -s -# \
				  -w "%{http_code}" -o "$resultfile" \
				  -H "X-API-Key: $cf_token" \
				  -A "GitHub Curseforge Packager/1.0" \
				  -F "name=$nolib_archive_version" \
				  -F "game_versions=$game_version_id" \
				  -F "file_type=$file_type" \
				  -F "change_log=<$pkgdir/$changelog" \
				  -F "change_markup_type=$changelog_markup" \
				  -F "known_caveats=" \
				  -F "caveats_markup_type=plain" \
				  -F "file=@$nolib_archive" \
				  "$url/upload-file.json" )

			case $result in
			201) echo "Success!" ;;
			403) echo "Error! Incorrect api key or you do not have permission to upload files." ;;
			404) echo "Error! No project for \`\`$slug'' found." ;;
			422) echo "Error! $(<"$resultfile")" ;;
			*) echo "Error! Unknown error ($result)." ;;
			esac
			if [ "$result" -ne "201" ]; then
				exit_code=1
			fi

			rm "$resultfile" 2>/dev/null
		fi

		echo
		echo "Uploading $archive_name ($file_type - $game_version_id) to $url"

		resultfile="$releasedir/cfresult" # json response
		result=$( curl -s -# \
			  -w "%{http_code}" -o "$resultfile" \
			  -H "X-API-Key: $cf_token" \
			  -A "GitHub Curseforge Packager/1.0" \
			  -F "name=$archive_version" \
			  -F "game_versions=$game_version_id" \
			  -F "file_type=$file_type" \
			  -F "change_log=<$pkgdir/$changelog" \
			  -F "change_markup_type=$changelog_markup" \
			  -F "known_caveats=" \
			  -F "caveats_markup_type=plain" \
			  -F "file=@$archive" \
			  "$url/upload-file.json" )

		case $result in
		201) echo "Success!" ;;
		403) echo "Error! Incorrect api key or you do not have permission to upload files." ;;
		404) echo "Error! No project for \`\`$slug'' found." ;;
		422) echo "Error! $(<"$resultfile")" ;;
		*) echo "Error! Unknown error ($result)." ;;
		esac
		if [ "$result" -ne "201" ]; then
			exit_code=1
		fi

		rm "$resultfile" 2>/dev/null
	fi

	# Upload tags to WoWInterface.
	if [ -n "$upload_wowinterface" ]; then
		# make a cookie to authenticate with (no oauth/token api yet)
		cookies="$releasedir/cookies.txt"
		curl -s -o /dev/null -c "$cookies" -d "vb_login_username=$wowi_user&vb_login_password=$wowi_pass&do=login&cookieuser=1" "https://secure.wowinterface.com/forums/login.php" 2>/dev/null

		if [ -s "$cookies" ]; then
			echo
			echo "Uploading $archive_name ($game_version) to http://http://www.wowinterface.com/downloads/info$addonid"

			# post just what is needed to add a new file
			result=$( curl -s -# \
				  -w "%{http_code} %{time_total}s\\n" \
				  -b "$cookies" \
				  -F "id=$addonid" \
				  -F "version=$archive_version" \
				  -F "compatible=$game_version" \
				  -F "updatefile=@$archive" \
				  "http://api.wowinterface.com/addons/update" )
			echo "Done. $result"
		else
			echo
			echo "Unable to upload to WoWInterface, authentication error."
			exit_code=1
		fi

		rm "$cookies" 2>/dev/null
	fi

	# Create a GitHub Release for tags and upload the zipfile as an asset.
	if [ -n "$upload_github" ]; then
		resultfile="$releasedir/ghresult" # github json response

		cat <<- EOF > "$releasedir/release.json"
		{
		  "tag_name": "$tag",
		  "target_commitish": "master",
		  "name": "$tag",
		  "body": $( cat "$pkgdir/$changelog" | jq --slurp --raw-input '.' ),
		  "draft": false,
		  "prerelease": false
		}
		EOF

		# check if a release exists and delete it (fuck yo couch)
		release_id=$( curl -s "https://api.github.com/repos/${project_github_slug}/releases/tags/$tag" | jq '.id' )
		if [ -n "$release_id" ]; then
			curl -s -H "Authorization: token $github_token" -X DELETE "https://api.github.com/repos/${project_github_slug}/releases/$release_id" &>/dev/null
			# possible responses: 204 = success, 401 = bad token, 404 = no token or invalid id (wtf)
			# whatever, we'll display token errors when creating
			release_id=
		fi

		echo
		echo "Creating GitHub release: https://github.com/${project_github_slug}/releases/tag/$tag"
		result=$( curl -s \
			  -w "%{http_code}" -o "$resultfile" \
			  -H "Authorization: token $github_token" \
			  -d "@$releasedir/release.json" \
			  "https://api.github.com/repos/${project_github_slug}/releases" )

		if [ "$result" -eq "201" ]; then
			release_id=$( jq '.id' "$resultfile" )
			result=$( curl -s \
				  -w "%{http_code}" -o "$resultfile" \
				  -H "Authorization: token $github_token" \
				  -H "Content-Type: application/zip" \
				  --data-binary "@$archive" \
				  "https://uploads.github.com/repos/${project_github_slug}/releases/${release_id}/assets?name=$archive_name" )
			if [ "$result" -eq "201" ]; then
				echo "Success!"
			else
				echo "Error uploading zipfile ($result)"
				echo "$(<"$resultfile")"
				exit_code=1
			fi
		else
			echo "Error! ($result)"
			echo "$(<"$resultfile")"
			exit_code=1
		fi

		rm "$resultfile" 2>/dev/null
	fi
fi

# All done.

echo
echo "Packaging complete."
exit $exit_code

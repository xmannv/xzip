#!/usr/bin/env python3
"""
Generate appcast.xml from GitHub Releases
Automatically fetches release information and converts markdown to HTML
"""

import base64
import html
import json
import os
import sys
import re
import plistlib
import xml.etree.ElementTree as ET
from datetime import datetime
from typing import Dict, List, Optional
import urllib.request
import urllib.error

# Sparkle reads these from the appcast; keep the URI in one place so the
# ElementTree namespace map and every qualified tag name stay in sync.
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'

# Sparkle compares sparkle:version numerically and shows shortVersionString to
# the user, so both must be plain dotted numbers. Anything else is a sign the
# tag/version.json was crafted (or simply wrong) and must not reach the feed.
VERSION_RE = re.compile(r'[0-9][0-9.]*')

# The release notes are rendered by Sparkle in a WebView, so a link target is
# executable content: only these schemes may survive into an href.
SAFE_LINK_SCHEMES = ('http://', 'https://', 'mailto:')


def fetch_github_releases(repo: str, token: Optional[str] = None) -> List[Dict]:
    """Fetch releases from GitHub API"""
    url = f"https://api.github.com/repos/{repo}/releases"
    headers = {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'XZip-Appcast-Generator'
    }

    if token:
        headers['Authorization'] = f'token {token}'

    req = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode())
    except urllib.error.URLError as e:
        # URLError covers HTTPError plus network-down; without it a transient
        # outage escaped as an uncaught traceback that failed CI opaquely.
        print(f"Error fetching releases: {e}", file=sys.stderr)
        sys.exit(1)


def is_safe_link(url: str) -> bool:
    """True when `url` uses a scheme that is safe to put in an href.

    Blocks javascript:/data: (and anything else, including scheme-relative and
    relative targets) because Sparkle renders the notes in a WebView where such
    a target would execute in the updater's context.
    """
    return url.strip().lower().startswith(SAFE_LINK_SCHEMES)


def _render_link(match: 're.Match[str]') -> str:
    label, target = match.group(1), match.group(2)
    # Keep the visible label when the target is rejected: the note still reads
    # correctly and a blocked scheme cannot be smuggled through as markup.
    if not is_safe_link(target):
        return label
    return f'<a href="{target}">{label}</a>'


def markdown_to_html(markdown: str) -> str:
    """Convert markdown to the small HTML subset Sparkle displays.

    The body is HTML-escaped BEFORE any conversion, so a release body can only
    ever contribute text and the tags below are the only markup in the output.
    Escaping first also neutralizes attribute breakouts: a quote inside a link
    target is already `&quot;` by the time it reaches an href.
    """
    text = html.escape(markdown, quote=True)

    # Headers
    text = re.sub(r'^### (.*?)$', r'<h3>\1</h3>', text, flags=re.MULTILINE)
    text = re.sub(r'^## (.*?)$', r'<h2>\1</h2>', text, flags=re.MULTILINE)
    text = re.sub(r'^# (.*?)$', r'<h1>\1</h1>', text, flags=re.MULTILINE)

    # Bold and italic
    text = re.sub(r'\*\*\*(.+?)\*\*\*', r'<strong><em>\1</em></strong>', text)
    text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'\*(.+?)\*', r'<em>\1</em>', text)
    text = re.sub(r'__(.+?)__', r'<strong>\1</strong>', text)
    text = re.sub(r'_(.+?)_', r'<em>\1</em>', text)

    # Links: the target must pass the scheme allowlist to become an href.
    text = re.sub(r'\[([^\]]+?)\]\(([^)\s]+?)\)', _render_link, text)

    # Code blocks
    text = re.sub(r'```[\w]*\n(.*?)\n```', r'<pre><code>\1</code></pre>', text, flags=re.DOTALL)
    text = re.sub(r'`(.+?)`', r'<code>\1</code>', text)

    # Lists
    lines = text.split('\n')
    in_ul = False
    in_ol = False
    result = []

    for line in lines:
        # Unordered list
        if re.match(r'^[\*\-\+] ', line):
            if not in_ul:
                result.append('<ul>')
                in_ul = True
            result.append(f'<li>{line[2:].strip()}</li>')
        # Ordered list
        elif re.match(r'^\d+\. ', line):
            if not in_ol:
                result.append('<ol>')
                in_ol = True
            cleaned_line = re.sub(r'^\d+\. ', '', line).strip()
            result.append(f'<li>{cleaned_line}</li>')
        else:
            if in_ul:
                result.append('</ul>')
                in_ul = False
            if in_ol:
                result.append('</ol>')
                in_ol = False
            if line.strip():
                result.append(f'<p>{line}</p>')

    if in_ul:
        result.append('</ul>')
    if in_ol:
        result.append('</ol>')

    return '\n'.join(result)


def find_dmg_asset(assets: List[Dict]) -> Optional[Dict]:
    """Find the main DMG file in release assets"""
    # Look for XZip.dmg first
    for asset in assets:
        if asset['name'] == 'XZip.dmg':
            return asset

    # Fallback to any .dmg file (e.g. versioned XZip-1.0.0.dmg)
    for asset in assets:
        if asset['name'].endswith('.dmg'):
            return asset

    return None


def find_signature_asset(assets: List[Dict]) -> Optional[Dict]:
    """Find the EdDSA signature file in release assets"""
    for asset in assets:
        if asset['name'] == 'signature.txt':
            return asset
    return None


def fetch_signature(signature_asset: Dict, token: Optional[str] = None) -> Optional[str]:
    """Fetch the EdDSA signature content from the asset"""
    if not signature_asset:
        return None

    url = signature_asset['browser_download_url']
    headers = {
        'User-Agent': 'XZip-Appcast-Generator'
    }

    if token:
        headers['Authorization'] = f'token {token}'

    req = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(req) as response:
            content = response.read().decode().strip()
            # The signature file may contain just the signature or be in format:
            # sparkle:edSignature="..." length="..."
            # Extract just the signature
            if 'sparkle:edSignature=' in content:
                match = re.search(r'sparkle:edSignature="([^"]+)"', content)
                if match:
                    return match.group(1)
            return content
    except urllib.error.URLError as e:
        # URLError covers HTTPError plus network-down failures; catching only
        # HTTPError before let a bare connection error crash CI with a traceback.
        print(f"Warning: Could not fetch signature: {e}", file=sys.stderr)
        return None


def find_version_json_asset(assets: List[Dict]) -> Optional[Dict]:
    """Find the version.json file in release assets"""
    for asset in assets:
        if asset['name'] == 'version.json':
            return asset
    return None


def fetch_version_info(version_asset: Dict, token: Optional[str] = None) -> Optional[Dict]:
    """Fetch version info from version.json asset"""
    if not version_asset:
        return None

    url = version_asset['browser_download_url']
    headers = {
        'User-Agent': 'XZip-Appcast-Generator'
    }

    if token:
        headers['Authorization'] = f'token {token}'

    req = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(req) as response:
            content = response.read().decode().strip()
            return json.loads(content)
    except (urllib.error.URLError, json.JSONDecodeError) as e:
        # URLError also covers a network-down failure that would otherwise crash
        # CI with an uncaught traceback (HTTPError is a subclass of URLError).
        print(f"Warning: Could not fetch version.json: {e}", file=sys.stderr)
        return None


def format_rfc822_date(iso_date: str) -> str:
    """Convert ISO 8601 date to RFC 822 format"""
    dt = datetime.fromisoformat(iso_date.replace('Z', '+00:00'))
    return dt.strftime('%a, %d %b %Y %H:%M:%S %z')


def find_local_dmg(dmg_asset: Dict) -> Optional[str]:
    """Locate a locally available copy of the release DMG for verification.

    Checks DMG_PATH (a direct file path) then DMG_DIR/<asset name>. Returns None
    when no local copy is present; the DMG is not downloaded here, so callers
    then skip verification with a warning rather than trusting blindly.
    """
    direct = os.getenv('DMG_PATH')
    if direct and os.path.isfile(direct):
        return direct
    dmg_dir = os.getenv('DMG_DIR')
    if dmg_dir:
        candidate = os.path.join(dmg_dir, dmg_asset['name'])
        if os.path.isfile(candidate):
            return candidate
    return None


def load_su_public_ed_key() -> Optional[str]:
    """Read the Sparkle SUPublicEDKey from the environment or the app Info.plist."""
    env_key = os.getenv('SU_PUBLIC_ED_KEY')
    if env_key:
        return env_key.strip()
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    info_plist = os.path.join(repo_root, 'apps', 'macos', 'XZip', 'Info.plist')
    try:
        with open(info_plist, 'rb') as f:
            plist = plistlib.load(f)
        key = plist.get('SUPublicEDKey')
        if key:
            return key.strip()
    except (OSError, plistlib.InvalidFileException):
        pass
    return None


def verification_required() -> bool:
    """True when a missing precondition must fail the run instead of warning.

    CI sets REQUIRE_VERIFICATION=1 (see update-appcast.yml). Without it, the
    three preconditions below (local DMG, public key, `cryptography` installed)
    each degraded to a warning, which meant the signature check silently never
    ran and the appcast shipped on an unverified base64 shape alone.
    """
    return os.getenv('REQUIRE_VERIFICATION', '') not in ('', '0', 'false', 'False')


def _missing_precondition(message: str) -> None:
    """Abort when verification is mandatory, otherwise warn and skip."""
    if verification_required():
        print(f"Error: {message} (REQUIRE_VERIFICATION is set)", file=sys.stderr)
        sys.exit(1)
    print(f"Warning: {message}", file=sys.stderr)


def verify_release_binary(dmg_asset: Dict, ed_signature: str, tag: str) -> None:
    """Fail-closed verification of the DMG enclosure length and EdDSA signature.

    Every mismatch aborts the whole script so a stale/mismatched signature never
    ships an appcast that every Sparkle client would reject silently. The three
    preconditions are only skippable for local dry runs; under
    REQUIRE_VERIFICATION they are fatal.
    """
    dmg_path = find_local_dmg(dmg_asset)
    if not dmg_path:
        _missing_precondition(
            f"DMG for {tag} not available locally, so size and EdDSA "
            f"verification cannot run (set DMG_PATH or DMG_DIR)")
        return

    # (a) The enclosure length must match the real file size.
    actual_size = os.path.getsize(dmg_path)
    expected_size = dmg_asset['size']
    if actual_size != expected_size:
        print(f"Error: DMG size mismatch for {tag}: enclosure length={expected_size} "
              f"but {dmg_path} is {actual_size} bytes.", file=sys.stderr)
        sys.exit(1)

    # (b) The EdDSA signature must validate against SUPublicEDKey.
    public_key = load_su_public_ed_key()
    if not public_key:
        _missing_precondition(
            f"SUPublicEDKey not found, so EdDSA verification cannot run for "
            f"{tag} (set SU_PUBLIC_ED_KEY)")
        return
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        from cryptography.exceptions import InvalidSignature
    except ImportError:
        _missing_precondition(
            f"'cryptography' not importable, so EdDSA verification cannot run "
            f"for {tag} (pip install cryptography)")
        return

    try:
        pub = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key))
        signature = base64.b64decode(ed_signature)
        with open(dmg_path, 'rb') as f:
            pub.verify(signature, f.read())
    except InvalidSignature:
        print(f"Error: EdDSA signature does not match the DMG for {tag}. Refusing "
              f"to publish an appcast every Sparkle client would reject.",
              file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        # A malformed key/signature reaching an actual verification attempt is
        # also fail-closed: never ship an unverifiable signature.
        print(f"Error: EdDSA verification failed for {tag}: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Verified DMG size and EdDSA signature for {tag}.", file=sys.stderr)


def validated_version(value: object, field: str, tag: str) -> str:
    """Return `value` as a string, aborting unless it is a plain dotted number.

    Sparkle compares sparkle:version to decide whether to offer an update, so a
    non-numeric value is either a mistake that breaks comparison or an attempt
    to smuggle content in through a release tag / version.json. Reject it here,
    before it reaches the feed, rather than relying on escaping alone.
    """
    text = str(value).strip()
    if not VERSION_RE.fullmatch(text):
        print(f"Error: Invalid {field} for release {tag}: {text!r} does not match "
              f"{VERSION_RE.pattern}.", file=sys.stderr)
        sys.exit(1)
    return text


def sparkle_tag(name: str) -> str:
    """Qualified name for a sparkle:-prefixed element."""
    return f'{{{SPARKLE_NS}}}{name}'


def generate_appcast_xml(repo: str, token: Optional[str] = None) -> str:
    """Generate complete appcast.xml from GitHub releases.

    Built with ElementTree rather than string concatenation: every value below
    comes from the GitHub API (release title, notes, asset URLs) and the
    serializer escapes each one, so no release content can close a tag or an
    attribute and inject into the feed Sparkle trusts for auto-updates.
    """
    releases = fetch_github_releases(repo, token)

    repo_owner = repo.split('/')[0]
    repo_name = repo.split('/')[1]

    ET.register_namespace('sparkle', SPARKLE_NS)
    ET.register_namespace('dc', 'http://purl.org/dc/elements/1.1/')

    rss = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'XZip Updates'
    ET.SubElement(channel, 'link').text = (
        f'https://{repo_owner}.github.io/{repo_name}/appcast.xml'
    )
    ET.SubElement(channel, 'description').text = 'XZip - Compression App for macOS'
    ET.SubElement(channel, 'language').text = 'en'

    # Process releases (only the latest one)
    items_added = 0
    for release in releases:
        # Skip drafts and pre-releases
        if release.get('draft') or release.get('prerelease'):
            continue

        release_tag = release['tag_name']

        # Find DMG asset
        dmg_asset = find_dmg_asset(release.get('assets', []))
        if not dmg_asset:
            print(f"Warning: No DMG found for release {release_tag}", file=sys.stderr)
            continue

        # Find and fetch EdDSA signature
        signature_asset = find_signature_asset(release.get('assets', []))
        ed_signature = fetch_signature(signature_asset, token)

        if not ed_signature:
            print(f"Error: No EdDSA signature found for release {release_tag}", file=sys.stderr)
            print(f"       Refusing to generate an appcast that Sparkle cannot validate.", file=sys.stderr)
            sys.exit(1)

        if not re.fullmatch(r'[A-Za-z0-9+/=]{80,}', ed_signature):
            print(f"Error: Invalid EdDSA signature format for release {release_tag}", file=sys.stderr)
            print(f"       Value: {ed_signature}", file=sys.stderr)
            sys.exit(1)

        # A base64 format match alone does not prove the signature is real: verify
        # the enclosure length and the EdDSA signature against the DMG bytes and
        # SUPublicEDKey (fail-closed on mismatch, and on a missing precondition
        # when REQUIRE_VERIFICATION is set).
        verify_release_binary(dmg_asset, ed_signature, release_tag)

        # Find and fetch version info from version.json
        version_asset = find_version_json_asset(release.get('assets', []))
        version_info = fetch_version_info(version_asset, token)

        # Extract version and build number
        if version_info:
            short_version = version_info.get('version', '')
            build_number = version_info.get('build', '')
            print(f"Found version.json: version={short_version}, build={build_number}", file=sys.stderr)
        else:
            # Fallback: extract from tag (format: v1.0.0 or v1.0.0-2)
            tag = release_tag.lstrip('v')
            if '-' in tag:
                parts = tag.split('-', 1)
                short_version = parts[0]
                build_number = parts[1]
            else:
                short_version = tag
                build_number = tag  # Use version as build number when the tag carries no build
            print(f"No version.json, extracted from tag: version={short_version}, build={build_number}", file=sys.stderr)

        short_version = validated_version(short_version, 'sparkle:shortVersionString', release_tag)
        build_number = validated_version(build_number, 'sparkle:version', release_tag)

        # Convert release notes markdown to HTML
        release_notes = release.get('body', '')
        release_notes_html = markdown_to_html(release_notes) if release_notes else ''

        # Add link to full release notes
        release_url = release['html_url']
        if release_notes_html and is_safe_link(release_url):
            release_notes_html += f'\n<p><a href="{html.escape(release_url, quote=True)}">View details on GitHub</a></p>'

        # Parse and format published date
        pub_date = release.get('published_at', release.get('created_at'))
        formatted_date = format_rfc822_date(pub_date)

        item = ET.SubElement(channel, 'item')
        ET.SubElement(item, 'title').text = f'Version {short_version} (Build {build_number})'
        ET.SubElement(item, 'link').text = release_url
        # sparkle:version is the build number (used for update comparison);
        # sparkle:shortVersionString is the display version.
        ET.SubElement(item, sparkle_tag('version')).text = build_number
        ET.SubElement(item, sparkle_tag('shortVersionString')).text = short_version
        # Plain text node, not CDATA: the notes are already HTML-escaped, and the
        # XML parser hands Sparkle back the same HTML string without the ']]>'
        # early-close hazard a CDATA section carries.
        ET.SubElement(item, 'description').text = release_notes_html
        ET.SubElement(item, 'pubDate').text = formatted_date
        ET.SubElement(item, sparkle_tag('minimumSystemVersion')).text = '15.0'
        ET.SubElement(item, 'enclosure', {
            'url': dmg_asset['browser_download_url'],
            sparkle_tag('version'): build_number,
            sparkle_tag('shortVersionString'): short_version,
            'length': str(dmg_asset['size']),
            'type': 'application/octet-stream',
            sparkle_tag('edSignature'): ed_signature,
        })

        items_added += 1
        # Only include the latest release
        break

    if items_added == 0:
        print("Warning: No valid releases found", file=sys.stderr)

    ET.indent(rss, space='  ')
    appcast_xml = ET.tostring(
        rss, encoding='unicode', xml_declaration=True, short_empty_elements=True
    )

    # Belt and braces: ElementTree emits well-formed XML by construction, but a
    # broken appcast.xml kills updates for every client, so re-parse before we
    # ever write or deploy it.
    try:
        ET.fromstring(appcast_xml)
    except ET.ParseError as e:
        print(f"Error: Generated appcast.xml is not well-formed XML: {e}", file=sys.stderr)
        sys.exit(1)

    return appcast_xml


def main():
    # Get repository from environment or argument
    repo = os.getenv('GITHUB_REPOSITORY', 'xmannv/xzip')
    token = os.getenv('GITHUB_TOKEN')

    # Generate appcast XML
    appcast_xml = generate_appcast_xml(repo, token)

    # Write to file
    output_path = os.getenv('OUTPUT_PATH', 'appcast.xml')
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(appcast_xml)

    print(f"✅ Generated appcast.xml")
    print(f"📝 Output: {output_path}")


if __name__ == '__main__':
    main()

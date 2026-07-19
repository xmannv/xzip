#!/usr/bin/env python3
"""
Generate appcast.xml from GitHub Releases
Automatically fetches release information and converts markdown to HTML
"""

import base64
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


def markdown_to_html(markdown: str) -> str:
    """Convert markdown to HTML (simple implementation)"""
    html = markdown

    # Headers
    html = re.sub(r'^### (.*?)$', r'<h3>\1</h3>', html, flags=re.MULTILINE)
    html = re.sub(r'^## (.*?)$', r'<h2>\1</h2>', html, flags=re.MULTILINE)
    html = re.sub(r'^# (.*?)$', r'<h1>\1</h1>', html, flags=re.MULTILINE)

    # Bold and italic
    html = re.sub(r'\*\*\*(.+?)\*\*\*', r'<strong><em>\1</em></strong>', html)
    html = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', html)
    html = re.sub(r'\*(.+?)\*', r'<em>\1</em>', html)
    html = re.sub(r'__(.+?)__', r'<strong>\1</strong>', html)
    html = re.sub(r'_(.+?)_', r'<em>\1</em>', html)

    # Links
    html = re.sub(r'\[(.+?)\]\((.+?)\)', r'<a href="\2">\1</a>', html)

    # Code blocks
    html = re.sub(r'```[\w]*\n(.*?)\n```', r'<pre><code>\1</code></pre>', html, flags=re.DOTALL)
    html = re.sub(r'`(.+?)`', r'<code>\1</code>', html)

    # Lists
    lines = html.split('\n')
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


def escape_cdata(text: str) -> str:
    """Neutralize any ']]>' inside CDATA content.

    A literal ']]>' (easy to hit in a fenced code block in the release notes)
    would close the CDATA section early, corrupting appcast.xml and allowing XML
    injection into the feed. Splitting it across two CDATA sections keeps the
    exact same rendered text while preventing the early close.
    """
    return text.replace(']]>', ']]]]><![CDATA[>')


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


def verify_release_binary(dmg_asset: Dict, ed_signature: str, tag: str) -> None:
    """Fail-closed verification of the DMG enclosure length and EdDSA signature.

    Runs only when a local DMG copy is available (see find_local_dmg); otherwise
    it logs a clear warning and trusts GitHub's reported metadata. When it does
    run, any mismatch aborts the whole script so a stale/mismatched signature
    never ships an appcast that every Sparkle client would reject silently.
    """
    dmg_path = find_local_dmg(dmg_asset)
    if not dmg_path:
        print(f"Warning: DMG for {tag} not available locally; skipping size and "
              f"EdDSA verification (set DMG_PATH or DMG_DIR to enable).",
              file=sys.stderr)
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
        print(f"Warning: SUPublicEDKey not found (set SU_PUBLIC_ED_KEY); skipping "
              f"EdDSA verification for {tag}.", file=sys.stderr)
        return
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        from cryptography.exceptions import InvalidSignature
    except ImportError:
        print(f"Warning: 'cryptography' not importable; skipping EdDSA "
              f"verification for {tag}.", file=sys.stderr)
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


def generate_appcast_xml(repo: str, token: Optional[str] = None) -> str:
    """Generate complete appcast.xml from GitHub releases"""
    releases = fetch_github_releases(repo, token)

    repo_owner = repo.split('/')[0]
    repo_name = repo.split('/')[1]

    # Start building XML manually to properly handle CDATA
    xml_lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">',
        '  <channel>',
        '    <title>XZip Updates</title>',
        f'    <link>https://{repo_owner}.github.io/{repo_name}/appcast.xml</link>',
        '    <description>XZip - Compression App for macOS</description>',
        '    <language>en</language>',
    ]

    # Process releases (only the latest one)
    items_added = 0
    for release in releases:
        # Skip drafts and pre-releases
        if release.get('draft') or release.get('prerelease'):
            continue

        # Find DMG asset
        dmg_asset = find_dmg_asset(release.get('assets', []))
        if not dmg_asset:
            print(f"Warning: No DMG found for release {release['tag_name']}", file=sys.stderr)
            continue

        # Find and fetch EdDSA signature
        signature_asset = find_signature_asset(release.get('assets', []))
        ed_signature = fetch_signature(signature_asset, token)

        if not ed_signature:
            print(f"Error: No EdDSA signature found for release {release['tag_name']}", file=sys.stderr)
            print(f"       Refusing to generate an appcast that Sparkle cannot validate.", file=sys.stderr)
            sys.exit(1)

        if not re.fullmatch(r'[A-Za-z0-9+/=]{80,}', ed_signature):
            print(f"Error: Invalid EdDSA signature format for release {release['tag_name']}", file=sys.stderr)
            print(f"       Value: {ed_signature}", file=sys.stderr)
            sys.exit(1)

        # A base64 format match alone does not prove the signature is real: verify
        # the enclosure length and the EdDSA signature against the DMG bytes and
        # SUPublicEDKey when both are locally available (fail-closed on mismatch).
        verify_release_binary(dmg_asset, ed_signature, release['tag_name'])

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
            tag = release['tag_name'].lstrip('v')
            if '-' in tag:
                parts = tag.split('-', 1)
                short_version = parts[0]
                build_number = parts[1]
            else:
                short_version = tag
                build_number = tag  # Use version as build number for backward compatibility
            print(f"No version.json, extracted from tag: version={short_version}, build={build_number}", file=sys.stderr)

        # Convert release notes markdown to HTML
        release_notes = release.get('body', '')
        release_notes_html = markdown_to_html(release_notes) if release_notes else ''

        # Add link to full release notes
        release_url = release['html_url']
        if release_notes_html:
            release_notes_html += f'\n<p><a href="{release_url}">View details on GitHub</a></p>'

        # Parse and format published date
        pub_date = release.get('published_at', release.get('created_at'))
        formatted_date = format_rfc822_date(pub_date)

        # Build enclosure attributes
        # sparkle:version is the build number (for update comparison)
        # sparkle:shortVersionString is the display version
        enclosure_attrs = [
            f'url="{dmg_asset["browser_download_url"]}"',
            f'sparkle:version="{build_number}"',
            f'sparkle:shortVersionString="{short_version}"',
            f'length="{dmg_asset["size"]}"',
            'type="application/octet-stream"',
        ]

        # Add EdDSA signature if available
        if ed_signature:
            enclosure_attrs.append(f'sparkle:edSignature="{ed_signature}"')

        enclosure_str = ' '.join(enclosure_attrs)

        # Add item
        xml_lines.extend([
            '    <item>',
            f'      <title>Version {short_version} (Build {build_number})</title>',
            f'      <link>{release_url}</link>',
            f'      <sparkle:version>{build_number}</sparkle:version>',
            f'      <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>',
            f'      <description><![CDATA[',
            f'        {escape_cdata(release_notes_html)}',
            f'      ]]></description>',
            f'      <pubDate>{formatted_date}</pubDate>',
            f'      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>',
            f'      <enclosure {enclosure_str} />',
            '    </item>',
        ])

        items_added += 1
        # Only include the latest release
        break

    if items_added == 0:
        print("Warning: No valid releases found", file=sys.stderr)

    # Close XML
    xml_lines.extend([
        '  </channel>',
        '</rss>',
    ])

    appcast_xml = '\n'.join(xml_lines)

    # Fail before writing/deploying if the generated feed is not well-formed XML
    # (e.g. an unescaped sequence slipped into the release notes). A broken
    # appcast.xml makes every Sparkle client fail to parse and kills updates.
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

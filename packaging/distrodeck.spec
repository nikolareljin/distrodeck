Name:           distrodeck
Version:        0.10.3
Release:        1%{?dist}
Summary:        Export and restore packages before distro upgrades
License:        MIT
URL:            https://github.com/nikolareljin/distrodeck
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

Requires:       python3

%description
Distrodeck exports installed packages and sources, then re-installs them after a distro upgrade.

%prep
%autosetup -n %{name}-%{version}

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/distrodeck
mkdir -p %{buildroot}/usr/share/man/man1

install -m 0644 distrodeck.py %{buildroot}/usr/bin/distrodeck.py
install -m 0755 distrodeck %{buildroot}/usr/bin/distrodeck
install -m 0644 VERSION %{buildroot}/usr/share/distrodeck/VERSION
install -m 0644 docs/man/distrodeck.1 %{buildroot}/usr/share/man/man1/distrodeck.1

%files
/usr/bin/distrodeck
/usr/bin/distrodeck.py
/usr/share/distrodeck/VERSION
/usr/share/man/man1/distrodeck.1*

%changelog
* Tue Aug 25 2026 Nikola Reljin <nikola.reljin@gmail.com> - 0.10.3-1
- Fix Debian artifact staging and RPM CI build paths

* Thu Jan 09 2026 Nikola Reljin <nikola.reljin@gmail.com> - 0.3.0-1
- Initial release

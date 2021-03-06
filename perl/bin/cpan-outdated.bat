@rem = '--*-Perl-*--
@echo off
if "%OS%" == "Windows_NT" goto WinNT
IF EXIST "%~dp0perl.exe" (
"%~dp0perl.exe" -x -S "%0" %1 %2 %3 %4 %5 %6 %7 %8 %9
) ELSE IF EXIST "%~dp0..\..\bin\perl.exe" (
"%~dp0..\..\bin\perl.exe" -x -S "%0" %1 %2 %3 %4 %5 %6 %7 %8 %9
) ELSE (
perl -x -S "%0" %1 %2 %3 %4 %5 %6 %7 %8 %9
)

@set ErrorLevel=%ErrorLevel%
goto endofperl
:WinNT
IF EXIST "%~dp0perl.exe" (
"%~dp0perl.exe" -x -S %0 %*
) ELSE IF EXIST "%~dp0..\..\bin\perl.exe" (
"%~dp0..\..\bin\perl.exe" -x -S %0 %*
) ELSE (
perl -x -S %0 %*
)

@set ErrorLevel=%ErrorLevel%
if NOT "%COMSPEC%" == "%SystemRoot%\system32\cmd.exe" goto endofperl
if %errorlevel% == 9009 echo You do not have Perl in your PATH.
goto endofperl
@rem ';
#!/usr/bin/perl
#line 30
use strict;
use warnings;
use ExtUtils::Installed;
use Getopt::Long;
use Pod::Usage;
use File::Temp;
use File::Spec;
use Config;
use version;
use IO::Zlib;
use CPAN::DistnameInfo;
use Module::CoreList ();
use Module::Metadata;
use URI;
use constant WIN32 => $^O eq 'MSWin32';

our $VERSION = "0.29";

my $mirror = 'http://www.cpan.org/';
my $quote = WIN32 ? q/"/ : q/'/;
my $local_lib;
my $self_contained = 0;
my $index_file;
Getopt::Long::Configure("bundling");
Getopt::Long::GetOptions(
    'h|help'          => \my $help,
    'verbose'         => \my $verbose,
    'm|mirror=s'      => \$mirror,
    'index'           => \$index_file,
    'p|print-package' => \my $print_package,
    'I=s'             => sub { die "this option was deprecated" },
    'l|local-lib=s'   => \$local_lib,
    'L|local-lib-contained=s' =>
      sub { $local_lib = $_[1]; $self_contained = 1; },
    'compare-changes' => sub {
        die "--compare-changes option was deprecated.\n"
          . "You can use 'cpan-listchanges `cpan-outdated -p`' instead.\n"
          . "cpanm cpan-listchanges # install from CPAN\n"
    },
    'exclude-core' => \my $exclude_core,
) or pod2usage();
pod2usage() if $help;

$mirror =~ s:/$::;
my $index_url = "${mirror}/modules/02packages.details.txt.gz";
$index_url = URI->new($index_url);
if ($index_url->isa('URI::file')) {
    die '--index is incompatible with a file:// mirror' if defined $index_file;
    $index_file = $index_url->file
}

my $core_modules = $Module::CoreList::version{$]};

unless ($ENV{HARNESS_ACTIVE}) {
    &main;
    exit;
}

sub modules_to_check {
    my @inc = @_;
    # TODO: if you want to filter the target modules, you can change them here.
    ExtUtils::Installed->new(skip_cwd => 1, inc_override => \@inc)->modules;
}

sub installed_version_for {
    my($pkg, $inc) = @_;

    local $SIG{__WARN__} = sub {};
    my $meta = Module::Metadata->new_from_module($pkg, inc => $inc);
    $meta ? $meta->version($pkg) : undef;
}

sub main {
    my @inc = make_inc($local_lib, $self_contained);

    if (   !defined($index_file)
        || ! -e $index_file || -z $index_file
        || !$index_url->isa('URI::file')) {

        $index_file = get_index($index_url, $index_file)
    }

    my %installed = map { $_ => 1 } modules_to_check(@inc);

    my $fh = zopen($index_file) or die "cannot open $index_file";
    # skip header part
    while (my $line = <$fh>) {
        last if $line eq "\n";
    }
    # body part
    my %seen;
    my %dist_latest_version;
    LINES: while (my $line = <$fh>) {
        my ($pkg, $version, $dist) = split /\s+/, $line;
        next unless $installed{$pkg};
        next if $version eq 'undef';

        # The note below about the latest version heuristics applies here too
        next if $seen{$dist};

        # $Mail::SpamAssassin::Conf::VERSION is 'bogus'
        # https://rt.cpan.org/Public/Bug/Display.html?id=73465
        next unless $version =~ /[0-9]/;
        
        # if excluding core modules
        next if $exclude_core && exists $core_modules->{$pkg};

        next if $dist =~ m{/perl-[0-9._]+\.tar\.(gz|bz2)$};

        my $inst_version = installed_version_for($pkg, \@inc)
            or next;

        if (compare_version($inst_version, $version)) {
            $seen{$dist}++;
            if ($verbose) {
                printf "%-30s %-7s %-7s %s\n", $pkg, $inst_version, $version, $dist;
            } elsif ($print_package) {
                print "$pkg\n";
            } else {
                print "$dist\n";
            }
        }
    }
}


# return true if $inst_version is less than $version
sub compare_version {
    my ($inst_version, $version) = @_;
    return 0 if $inst_version eq $version;

    my $inst_version_obj = eval { version->new($inst_version) } || version->new(permissive_filter($inst_version));
    my $version_obj      = eval { version->new($version) } || version->new(permissive_filter($version));

    return $inst_version_obj < $version_obj ? 1 : 0;
}

# for broken packages.
sub permissive_filter {
    local $_ = $_[0];
    s/^[Vv](\d)/$1/;                   # Bioinf V2.0
    s/^(\d+)_(\d+)$/$1.$2/;            # VMS-IndexedFile 0_02
    s/-[a-zA-Z]+$//;                   # Math-Polygon-Tree 0.035-withoutworldwriteables
    s/([a-j])/ord($1)-ord('a')/gie;    # DBD-Solid 0.20a
    s/[_h-z-]/./gi;                    # makepp 1.50.2vs.070506
    s/\.{2,}/./g;
    $_;
}

# taken from cpanminus
sub which {
    my($name) = @_;
    my $exe_ext = $Config{_exe};
    foreach my $dir(File::Spec->path){
        my $fullpath = File::Spec->catfile($dir, $name);
        if (-x $fullpath || -x ($fullpath .= $exe_ext)){
            if ($fullpath =~ /\s/ && $fullpath !~ /^$quote/) {
                $fullpath = "$quote$fullpath$quote"
            }
            return $fullpath;
        }
    }
    return;
}

# Return the $fname (a generated File::Temp object if not provided)
sub get_index {
    my ($url, $fname) = @_;
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(
        parse_head => 0,
    );
    $ua->env_proxy();
    $fname = File::Temp->new(UNLINK => 1, SUFFIX => '.gz') unless defined $fname;
    my $response;
    # If the file is not empty, use it as a local cached copy
    if (-s "$fname") {
        $response = $ua->mirror($url, "$fname"); # Explicitely stringify
    } else {
        # If the file is empty we do not trust its timestamp (as it may just
        # have been created if a temp file) so we can't use $ua->mirror
        $response = $ua->get($url, ':content_file' => "$fname");
    }
    if (my $died = $response->header('X-Died')) {
        die "Cannot get_index $url to $fname: $died";
    # 304 = "Not Modified" (returned if we are mirroring)
    } elsif (! $response->is_success && $response->code != 304) {
        die "Cannot get_index $url to $fname: " . $response->status_line;
    }
    #print "$fname ", $response->status_line, "\n";
    # Return the filename
    $fname
}

sub zopen {
    # Explicitely stringify the filename as it may be a File::Temp object
    IO::Zlib->new("$_[0]", "rb");
}

sub make_inc {
    my ($base, $self_contained) = @_;

    if ($base) {
        require local::lib;
        my @modified_inc = (
            local::lib->install_base_perl_path($base),
            local::lib->install_base_arch_path($base),
        );
        if ($self_contained) {
            push @modified_inc, @Config{qw(privlibexp archlibexp)};
        } else {
            push @modified_inc, @INC;
        }
        return @modified_inc;
    } else {
        return @INC;
    }
}

__END__

=head1 NAME

cpan-outdated - detect outdated CPAN modules in your environment

=head1 SYNOPSIS

    # print the list of distribution that contains outdated modules
    % cpan-outdated

    # print the list of outdated modules in packages
    % cpan-outdated -p

    # verbose
    % cpan-outdated --verbose
    
    # ignore core modules (do not update dual life modules)
    % cpan-outdated --exclude-core

    # alternate mirrors
    % cpan-outdated --mirror file:///home/user/minicpan/

    # additional module path(same as cpanminus)
    % cpan-outdated -l extlib/
    % cpan-outdated -L extlib/

    # install with cpan
    % cpan-outdated | xargs cpan -i

    # install with cpanm
    % cpan-outdated    | cpanm
    % cpan-outdated -p | cpanm

=head1 DESCRIPTION

This script prints the list of outdated CPAN modules in your machine.

It's same feature of 'CPAN::Shell->r', but C<cpan-outdated> is much faster and uses less memory.

This script can be integrated with L<cpanm> command.

=head1 PRINTING PACKAGES VS DISTRIBUTIONS

This script by default prints the outdated distribution as in the CPAN
distro format, i.e: C<A/AU/AUTHOR/Distribution-Name-0.10.tar.gz> so
you can pipe into CPAN installers, but with C<-p> option it can be
tweaked to print the module's package names.

If you wish to manage a set of modules separately from your system  
perl installation and not install newer versions of "dual life modules" 
that are distributed with perl, the C<--exclude-core> option will make 
cpan-outdated ignore changes to core modules. Used with tools like 
cpanm and its C<-L --local-lib-contained> and C<--self-contained> options, 
this facilitates maintaining updates on standalone sets of modules.

For some tools such as L<cpanm> installing from packages could be a
bit more useful since you can track to see the old version number
where you upgrade from.

=head1 AUTHOR

Tokuhiro Matsuno

=head1 LICENSE

Copyright (C) 2009 Tokuhiro Matsuno.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=head1 SEE ALSO

L<CPAN>

L<App::cpanminus>

If you want to see what's changed for modules that require upgrades, use L<cpan-listchanges>

=cut
__END__
:endofperl
@"%COMSPEC%" /c exit /b %ErrorLevel%

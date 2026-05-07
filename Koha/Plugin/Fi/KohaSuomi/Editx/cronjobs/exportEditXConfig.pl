#!/usr/bin/perl

use strict;
use warnings;
use Modern::Perl;
use FindBin qw($Bin);
use lib "$Bin/../../../../../..";

use C4::Context;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;

my $config = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config->new->getSettings();
my $settings = $config->{settings} || {};
my $notifications = $config->{notifications} || {};

my %exports = (
    mailto               => $notifications->{mailto} // '',
    mailfrom             => $notifications->{mailfrom} // '',
    tmp_path             => $settings->{import_tmp_path} // '',
    failed_path          => $settings->{import_failed_path} // '',
    failed_archived_path => $settings->{import_failed_archived_path} // '',
    archive_path         => $settings->{import_archive_path} // '',
    log_path             => C4::Context->config('logdir') // '',
);

for my $key ( sort keys %exports ) {
    print "export $key=" . shell_quote( $exports{$key} ) . "\n";
}

sub shell_quote {
    my ($value) = @_;

    $value //= '';
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

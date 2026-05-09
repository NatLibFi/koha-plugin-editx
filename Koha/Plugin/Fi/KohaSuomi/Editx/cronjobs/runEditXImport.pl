#!/usr/bin/perl

use strict;
use warnings;
use Modern::Perl;

use Koha::Plugins;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner;

my $result = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new->run;

print "EDItX import result: processed $result->{processed}, failed $result->{failed}, skipped $result->{skipped}.\n";

for my $error ( @{ $result->{errors} || [] } ) {
    my $message = $error->{error} // '';
    $message =~ s/\s+/ /g;
    $message =~ s/\A\s+|\s+\z//g;
    warn "Failed EDItX file $error->{file}: $message\n";
}

exit( $result->{failed} ? 1 : 0 );

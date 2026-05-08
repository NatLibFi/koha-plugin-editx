#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $order_processor = File::Spec->catfile(
    $Bin, '..', 'Koha', 'Plugin', 'Fi', 'KohaSuomi', 'Editx', 'Procurement', 'OrderProcessor.pm'
);

open my $fh, '<', $order_processor or die "Cannot read $order_processor: $!";
my $source = do { local $/; <$fh> };
close $fh;

like( $source, qr{sub\s+_table_exists\s*\{}, 'OrderProcessor has a table existence helper' );
like(
    $source,
    qr{!\$self->_table_exists\(\s*\$dbh,\s*'aqbudgets_spend_log'\s*\)},
    'Spend log update checks for the optional legacy table before insert'
);
like(
    $source,
    qr{Skipping aqbudgets_spend_log update because the table does not exist},
    'Missing optional spend log table is logged and skipped'
);
like(
    $source,
    qr{return\s+1;\s*\}\s*\n\s*my\s+\$copyQty},
    'Missing optional spend log table returns without failing import'
);

done_testing();

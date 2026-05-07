#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Find;
use File::Spec;
use Test::More;

my $plugin_root = File::Spec->catdir( $Bin, '..' );
my @core_candidates = (
    File::Spec->catdir( $plugin_root, '..', '..', 'Koha' ),
    File::Spec->catdir( $ENV{HOME} || q{}, 'git', 'koha', 'Koha' ),
    File::Spec->catdir( $ENV{HOME} || q{}, 'git', 'KohaCommunity' ),
    File::Spec->catdir( $ENV{HOME} || q{}, 'git', 'Koha' ),
);
my ($core_root) = grep { -d $_ } @core_candidates;

unshift @INC, $plugin_root;
if ($core_root) {
    unshift @INC, $core_root;
    unshift @INC, File::Spec->catdir( $core_root, 'misc', 'translator' );
    unshift @INC, File::Spec->catdir( $core_root, 't', 'lib' );
}

find(
    {
        bydepth  => 1,
        no_chdir => 1,
        wanted   => sub {
            my $module = $_;
            return unless $module =~ s/[.]pm$//;
            return unless $module =~ m{/Koha/};

            $module =~ s{^.*/Koha/}{Koha/};
            $module =~ s{/}{::}g;

            use_ok($module) || BAIL_OUT("Problems loading $module");
        },
    },
    File::Spec->catdir( $plugin_root, 'Koha' )
);

done_testing();

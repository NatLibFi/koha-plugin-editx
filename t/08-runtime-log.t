#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
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

use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog');
use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger');

my $tmpdir = tempdir( CLEANUP => 1 );
my $path = File::Spec->catfile( $tmpdir, 'editx-runtime.log' );

{
    no warnings 'once';
    no warnings 'redefine';
    local *Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog::path = sub {
        return $path;
    };

    ok(
        !Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->should_log(
            { runtime_log_level => 'warn' },
            'info'
        ),
        'Runtime log skips messages below the configured level'
    );
    ok(
        Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->should_log(
            { runtime_log_level => 'warn' },
            'error'
        ),
        'Runtime log writes messages at or above the configured level'
    );
    is(
        Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->normalize_level('surprise'),
        'info',
        'Runtime log normalizes unknown levels to info'
    );

    {
        package Editx::TestShortTimeZone;

        sub short_name_for_datetime {
            return 'EEST';
        }

        sub name {
            return 'Europe/Helsinki';
        }
    }

    {
        no warnings 'once';
        no warnings 'redefine';
        local *C4::Context::tz = sub {
            return bless {}, 'Editx::TestShortTimeZone';
        };

        like(
            Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->format_line(
                {
                    level   => 'info',
                    message => 'Short timezone',
                }
            ),
            qr{\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} EEST\] INFO Short timezone\n\z},
            'Runtime log uses the Koha timezone short name when available'
        );
    }

    Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->log(
        {
            settings => { runtime_log_level => 'warn' },
            level    => 'info',
            message  => 'Hidden info line',
        }
    );
    ok( !-e $path, 'Runtime log does not create a file for skipped messages' );

    Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->log(
        {
            settings  => { runtime_log_level => 'warn' },
            level     => 'error',
            message   => "Broken\nline",
            component => 'test',
            context   => {
                operation => 'nightly',
            },
        }
    );

    ok( -f $path, 'Runtime log creates the text log file' );
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read $path: $!";
    my $log_text = do { local $/; <$fh> };
    close $fh;

    like( $log_text, qr{\] ERROR Broken line }, 'Runtime log writes a one-line error message' );
    like( $log_text, qr{"operation":"nightly"}, 'Runtime log writes structured context as JSON' );
    like( $log_text, qr{"component":"test"}, 'Runtime log includes component context' );

    my $logger = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger->new(
        File::Spec->catdir( $tmpdir, 'legacy' )
    );
    $logger->debug('Hidden procurement debug line');
    $logger->error('Procurement bridge error');

    my $tail = Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->tail;
    like( $tail, qr{Procurement bridge error}, 'Procurement logger writes to runtime log' );
    unlike( $tail, qr{Hidden procurement debug line}, 'Procurement logger respects runtime log level' );
}

done_testing();

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

use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File');

{
    package Editx::FileTestLogger;

    sub new {
        my ($class) = @_;
        return bless { entries => [] }, $class;
    }

    sub log { return shift->_push( log => @_ ) }
    sub logError { return shift->_push( error => @_ ) }

    sub _push {
        my ( $self, $level, $message ) = @_;
        push @{ $self->{entries} }, [ $level, $message ];
        return 1;
    }

    sub messages {
        my ($self) = @_;
        return [ map { $_->[1] } @{ $self->{entries} } ];
    }
}

{
    package Editx::FileTestMsgUpdater;

    sub new {
        my ($class) = @_;
        return bless { updates => [] }, $class;
    }

    sub update {
        my ( $self, $file_name, $status ) = @_;
        push @{ $self->{updates} }, [ $file_name, $status ];
        return 1;
    }
}

sub _write_test_file {
    my ($file_path) = @_;

    open my $fh, '>', $file_path or die "Could not create $file_path: $!";
    print {$fh} '<notice />';
    close $fh or die "Could not close $file_path: $!";

    return;
}

sub _file_manager {
    my ( $archive_path, $fail_path ) = @_;

    my $logger = Editx::FileTestLogger->new;
    my $msg_updater = Editx::FileTestMsgUpdater->new;
    my $file_manager = bless {
        archive_path => $archive_path,
        fail_path    => $fail_path,
        logger       => $logger,
        edi_msg      => $msg_updater,
    }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File';

    return ( $file_manager, $logger, $msg_updater );
}

{
    no warnings qw(once redefine);
    local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File::saveFileHash = sub { return 1; };

    subtest 'archiveFile dies when the archive move fails' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $load_dir = File::Spec->catdir( $tmp_dir, 'load' );
        mkdir $load_dir or die "Could not create $load_dir: $!";

        my $file_path = File::Spec->catfile( $load_dir, 'order.xml' );
        _write_test_file($file_path);

        my ( $file_manager, $logger, $msg_updater ) = _file_manager( File::Spec->catdir( $tmp_dir, 'missing_archive' ) . '/', q{} );
        my $ok = eval {
            $file_manager->archiveFile($file_path);
            1;
        };

        ok( !$ok, 'archiveFile throws on move failure' );
        like( $@, qr{could not be moved to}, 'archiveFile reports the target move failure' );
        ok( -e $file_path, 'archiveFile leaves the source file in place when move fails' );
        is_deeply( $msg_updater->{updates}, [ [ 'order.xml', 'OK' ] ], 'archiveFile keeps the current EDI OK update before move' );
        like( join( "\n", @{ $logger->messages } ), qr{could not be moved to}, 'archiveFile logs the move failure' );
    };

    subtest 'moveToFailFolder dies when the fail-folder move fails' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $load_dir = File::Spec->catdir( $tmp_dir, 'load' );
        mkdir $load_dir or die "Could not create $load_dir: $!";

        my $file_path = File::Spec->catfile( $load_dir, 'order.xml' );
        _write_test_file($file_path);

        my ( $file_manager, $logger, $msg_updater ) = _file_manager( q{}, File::Spec->catdir( $tmp_dir, 'missing_failed' ) . '/' );
        my $ok = eval {
            $file_manager->moveToFailFolder($file_path);
            1;
        };

        ok( !$ok, 'moveToFailFolder throws on move failure' );
        like( $@, qr{could not be moved to}, 'moveToFailFolder reports the target move failure' );
        ok( -e $file_path, 'moveToFailFolder leaves the source file in place when move fails' );
        is_deeply( $msg_updater->{updates}, [ [ 'order.xml', 'FAILED' ] ], 'moveToFailFolder keeps the current EDI FAILED update before move' );
        like( join( "\n", @{ $logger->messages } ), qr{could not be moved to}, 'moveToFailFolder logs the move failure' );
    };
}

done_testing();

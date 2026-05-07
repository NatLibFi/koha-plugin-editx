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

    sub add {
        my ( $self, $file_name, $raw_message ) = @_;
        push @{ $self->{added} }, [ $file_name, $raw_message ];
        return 1;
    }

    sub findBookseller {
        my ( $self, $file_path ) = @_;
        push @{ $self->{bookseller_files} }, $file_path;
        return 1;
    }
}

{
    package Editx::FileTestDbh;

    sub new {
        my ( $class, $params ) = @_;
        $params ||= {};
        return bless { queries => [], prepared => [], executed => [], %$params }, $class;
    }

    sub selectrow_array {
        my ( $self, $sql, $attr, @bind ) = @_;
        push @{ $self->{queries} }, [ $sql, @bind ];
        return $self->{count} || 0;
    }

    sub prepare {
        my ( $self, $sql ) = @_;
        push @{ $self->{prepared} }, $sql;
        return Editx::FileTestSth->new($self);
    }

    sub errstr {
        return 'test db error';
    }
}

{
    package Editx::FileTestSth;

    sub new {
        my ( $class, $dbh ) = @_;
        return bless { dbh => $dbh }, $class;
    }

    sub execute {
        my ( $self, @bind ) = @_;
        push @{ $self->{dbh}->{executed} }, \@bind;
        return exists $self->{dbh}->{execute_result} ? $self->{dbh}->{execute_result} : 1;
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

    subtest 'discardDuplicateFile removes an already imported file' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $load_dir = File::Spec->catdir( $tmp_dir, 'load' );
        mkdir $load_dir or die "Could not create $load_dir: $!";

        my $file_path = File::Spec->catfile( $load_dir, 'order.xml' );
        _write_test_file($file_path);

        my ( $file_manager, $logger, $msg_updater ) = _file_manager( q{}, q{} );

        ok( $file_manager->discardDuplicateFile($file_path), 'discardDuplicateFile returns true on unlink success' );
        ok( !-e $file_path, 'discardDuplicateFile removes the duplicate source file' );
        is_deeply( $msg_updater->{updates}, [ [ 'order.xml', 'DUPLICATE' ] ], 'discardDuplicateFile marks the EDI message duplicate' );
        like( join( "\n", @{ $logger->messages } ), qr{already imported\. Removing it\.}, 'discardDuplicateFile logs the removal' );
    };

    subtest 'fillLoadFolder dies when a file cannot be staged for import' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $tmp_path = File::Spec->catdir( $tmp_dir, 'tmp' );
        mkdir $tmp_path or die "Could not create $tmp_path: $!";

        my $file_path = File::Spec->catfile( $tmp_path, 'order.xml' );
        open my $fh, '>', $file_path or die "Could not create $file_path: $!";
        print {$fh} '<LibraryShipNotice><Header><ShipNoticeNumber>ASN-TEST</ShipNoticeNumber></Header></LibraryShipNotice>';
        close $fh or die "Could not close $file_path: $!";

        my $logger = Editx::FileTestLogger->new;
        my $msg_updater = Editx::FileTestMsgUpdater->new;
        my $file_manager = bless {
            tmp_path  => $tmp_path . '/',
            load_path => File::Spec->catdir( $tmp_dir, 'missing_load' ) . '/',
            logger    => $logger,
            edi_msg   => $msg_updater,
        }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File';

        local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File::fileAlreadyImported = sub { return 0; };

        my $ok = eval {
            $file_manager->fillLoadFolder;
            1;
        };

        ok( !$ok, 'fillLoadFolder throws on staging move failure' );
        like( $@, qr{could not be moved to}, 'fillLoadFolder reports the staging move failure' );
        ok( -e $file_path, 'fillLoadFolder leaves the source file in tmp when staging fails' );
        is_deeply( $msg_updater->{updates}, [ [ 'order.xml', 'PROCESSING' ] ], 'fillLoadFolder keeps the current PROCESSING status update before move' );
        like( join( "\n", @{ $logger->messages } ), qr{could not be moved to}, 'fillLoadFolder logs the staging move failure' );
    };
}

{
    no warnings qw(once redefine);

    subtest 'filePathAlreadyImported checks the qualified procurement file table' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $file_path = File::Spec->catfile( $tmp_dir, 'order.xml' );
        _write_test_file($file_path);

        my ( $file_manager ) = _file_manager( q{}, q{} );
        my $dbh = Editx::FileTestDbh->new( { count => 1 } );

        local *C4::Context::dbh = sub { return $dbh; };

        is( $file_manager->filePathAlreadyImported($file_path), 1, 'filePathAlreadyImported returns true when a matching hash exists' );
        like(
            $dbh->{queries}->[0]->[0],
            qr{`koha_plugin_fi_kohasuomi_editx_procurement_file`},
            'filePathAlreadyImported reads from the qualified procurement file table'
        );
        is( $dbh->{queries}->[0]->[1], 'order.xml', 'filePathAlreadyImported binds the basename' );
    };

    subtest 'saveFileHash writes to the qualified procurement file table' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $file_path = File::Spec->catfile( $tmp_dir, 'order.xml' );
        _write_test_file($file_path);

        my ( $file_manager ) = _file_manager( q{}, q{} );
        my $dbh = Editx::FileTestDbh->new;

        local *C4::Context::dbh = sub { return $dbh; };

        $file_manager->saveFileHash( $file_path, 'order.xml' );

        like(
            $dbh->{prepared}->[0],
            qr{INSERT IGNORE INTO `koha_plugin_fi_kohasuomi_editx_procurement_file`},
            'saveFileHash inserts into the qualified procurement file table'
        );
        is( $dbh->{executed}->[0]->[0], 'order.xml', 'saveFileHash binds the file name' );
        ok( $dbh->{executed}->[0]->[1], 'saveFileHash binds the file hash' );
    };
}

done_testing();

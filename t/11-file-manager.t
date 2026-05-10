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

    subtest 'fillLoadFolder reports duplicates skipped before parser processing' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $tmp_path = File::Spec->catdir( $tmp_dir, 'tmp' );
        my $load_path = File::Spec->catdir( $tmp_dir, 'load' );
        mkdir $tmp_path or die "Could not create $tmp_path: $!";
        mkdir $load_path or die "Could not create $load_path: $!";

        my $file_path = File::Spec->catfile( $tmp_path, 'order.xml' );
        open my $fh, '>', $file_path or die "Could not create $file_path: $!";
        print {$fh} '<LibraryShipNotice><Header><ShipNoticeNumber>ASN-TEST</ShipNoticeNumber></Header></LibraryShipNotice>';
        close $fh or die "Could not close $file_path: $!";

        my $logger = Editx::FileTestLogger->new;
        my $msg_updater = Editx::FileTestMsgUpdater->new;
        my $file_manager = bless {
            tmp_path  => $tmp_path . '/',
            load_path => $load_path . '/',
            logger    => $logger,
            edi_msg   => $msg_updater,
        }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File';

        local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File::fileAlreadyImported = sub { return 1; };

        my $result = $file_manager->fillLoadFolder;

        is_deeply(
            $result,
            { staged => 0, skipped => 1, postponed => 0 },
            'fillLoadFolder returns a skipped count for duplicate tmp files'
        );
        ok( !-e $file_path, 'Duplicate tmp file is discarded during staging' );
        ok( !-e File::Spec->catfile( $load_path, 'order.xml' ), 'Duplicate tmp file is not moved to the load folder' );
        is_deeply(
            $msg_updater->{updates},
            [ [ 'order.xml', 'DUPLICATE' ] ],
            'Duplicate tmp file is marked as duplicate'
        );
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

    subtest 'registerFileForImport records a valid selected file for processing' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $file_path = File::Spec->catfile( $tmp_dir, 'order.xml' );
        _write_test_file($file_path);

        my ( $file_manager, undef, $msg_updater ) = _file_manager( q{}, q{} );

        ok( $file_manager->registerFileForImport($file_path), 'registerFileForImport accepts valid XML' );
        is_deeply( $msg_updater->{added}, [ [ 'order.xml', '<notice />' ] ], 'registerFileForImport stores the raw EDItX message' );
        is_deeply( $msg_updater->{bookseller_files}, [$file_path], 'registerFileForImport resolves the vendor before processing' );
        is_deeply( $msg_updater->{updates}, [ [ 'order.xml', 'PROCESSING' ] ], 'registerFileForImport marks the file as processing' );
    };

    subtest 'registerFileForImport postpones invalid XML before selected import parsing' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $file_path = File::Spec->catfile( $tmp_dir, 'broken.xml' );
        open my $fh, '>', $file_path or die "Could not create $file_path: $!";
        print {$fh} '<notice>';
        close $fh or die "Could not close $file_path: $!";

        my ( $file_manager, $logger, $msg_updater ) = _file_manager( q{}, q{} );

        my $ok = eval {
            $file_manager->registerFileForImport($file_path);
            1;
        };

        ok( !$ok, 'registerFileForImport throws on invalid XML' );
        like( $@, qr{File: \Q$file_path\E is not valid XML}, 'registerFileForImport reports the invalid selected file' );
        is_deeply( $msg_updater->{added}, [ [ 'broken.xml', '<notice>' ] ], 'registerFileForImport stores the raw invalid message for diagnostics' );
        ok( !exists $msg_updater->{bookseller_files}, 'registerFileForImport does not resolve a vendor for invalid XML' );
        is_deeply( $msg_updater->{updates}, [ [ 'broken.xml', 'POSTPONED' ] ], 'registerFileForImport marks invalid XML as postponed' );
        like( join( "\n", @{ $logger->messages } ), qr{not valid XML, processing postponed}, 'registerFileForImport logs the postponed file' );
    };
}

{
    no warnings qw(once redefine);

    subtest 'BUILD creates missing configured import folders' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $base_dir = File::Spec->catdir( $tmp_dir, 'spool', 'editx' );
        my %settings = (
            import_tmp_path     => File::Spec->catdir( $base_dir, 'tmp' ),
            import_load_path    => File::Spec->catdir( $base_dir, 'load' ),
            import_archive_path => File::Spec->catdir( $base_dir, 'archive' ),
            import_failed_path  => File::Spec->catdir( $base_dir, 'fail' ),
            log_directory       => File::Spec->catdir( $base_dir, 'log' ),
        );

        local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config::getSettings = sub {
            return { settings => \%settings, notifications => {} };
        };
        local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger::new = sub {
            return bless {}, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger';
        };
        local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EdiMessage::new = sub {
            return Editx::FileTestMsgUpdater->new;
        };

        my $file_manager = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File->new;

        for my $path ( @settings{qw(import_tmp_path import_load_path import_archive_path import_failed_path)} ) {
            ok( -d $path, "File manager created $path" );
        }
        is( $file_manager->getLoadPath, $settings{import_load_path} . '/', 'File manager keeps the normalized load path' );
    };

    subtest 'filePathAlreadyImported checks existing Koha acquisition baskets' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $file_path = File::Spec->catfile( $tmp_dir, 'order.xml' );
        open my $fh, '>', $file_path or die "Could not create $file_path: $!";
        print {$fh} '<LibraryShipNotice><Header><ShipNoticeNumber>ASN-TEST</ShipNoticeNumber></Header></LibraryShipNotice>';
        close $fh or die "Could not close $file_path: $!";

        my ( $file_manager ) = _file_manager( q{}, q{} );
        my $dbh = Editx::FileTestDbh->new( { count => 1 } );

        local *C4::Context::dbh = sub { return $dbh; };

        is( $file_manager->filePathAlreadyImported($file_path), 1, 'filePathAlreadyImported returns true when a matching basket exists' );
        like(
            $dbh->{queries}->[0]->[0],
            qr{FROM aqbasket\s+WHERE basketname = \?}s,
            'filePathAlreadyImported reads from Koha acquisition baskets'
        );
        is( $dbh->{queries}->[0]->[1], 'ASN-TEST', 'filePathAlreadyImported binds the EDItX ShipNoticeNumber as the basket name' );
    };

    subtest 'basketNameFromFile extracts the EDItX ShipNoticeNumber' => sub {
        my $tmp_dir = tempdir( CLEANUP => 1 );
        my $file_path = File::Spec->catfile( $tmp_dir, 'order.xml' );
        open my $fh, '>', $file_path or die "Could not create $file_path: $!";
        print {$fh} '<LibraryShipNotice><Header><ShipNoticeNumber>  22886798  </ShipNoticeNumber></Header></LibraryShipNotice>';
        close $fh or die "Could not close $file_path: $!";

        my ( $file_manager ) = _file_manager( q{}, q{} );

        is( $file_manager->basketNameFromFile($file_path), '22886798', 'ShipNoticeNumber whitespace is trimmed before basket lookup' );
    };
}

done_testing();

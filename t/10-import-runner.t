#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $plugin_root = File::Spec->catdir( $Bin, '..' );
unshift @INC, $plugin_root;

use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner');

{
    package Editx::TestLogger;

    sub new {
        my ($class) = @_;
        return bless { entries => [] }, $class;
    }

    sub debug { return shift->_push( debug => @_ ) }
    sub info { return shift->_push( info => @_ ) }
    sub notice { return shift->_push( notice => @_ ) }
    sub warn { return shift->_push( warn => @_ ) }
    sub error { return shift->_push( error => @_ ) }
    sub log { return shift->info(@_) }
    sub logError { return shift->error(@_) }

    sub _push {
        my ( $self, $level, $message, $echo ) = @_;
        push @{ $self->{entries} }, [ $level, $message, $echo ];
        return 1;
    }

    sub messages {
        my ($self) = @_;
        return [ map { $_->[1] } @{ $self->{entries} } ];
    }

    sub echoes {
        my ($self) = @_;
        return [ map { $_->[2] } @{ $self->{entries} } ];
    }
}

{
    package Editx::TestFileManager;

    sub new {
        my ( $class, $events, $params ) = @_;
        $params ||= {};
        return bless { events => $events, archived => [], failed => [], discarded => [], checked_imported => [], %$params }, $class;
    }

    sub fillLoadFolder {
        my ($self) = @_;
        push @{ $self->{events} }, 'fillLoadFolder';
        return $self->{fill_result} || { staged => 0, skipped => 0, postponed => 0 };
    }

    sub archiveFile {
        my ( $self, $file_name ) = @_;
        push @{ $self->{events} }, "archive:$file_name";
        die "archive failed for $file_name" if $self->{fail_archive};
        push @{ $self->{archived} }, $file_name;
        return 1;
    }

    sub moveToFailFolder {
        my ( $self, $file_name ) = @_;
        push @{ $self->{events} }, "fail:$file_name";
        die "fail move failed for $file_name" if $self->{fail_move};
        push @{ $self->{failed} }, $file_name;
        return 1;
    }

    sub filePathAlreadyImported {
        my ( $self, $file_name ) = @_;
        push @{ $self->{checked_imported} }, $file_name;
        return $self->{already_imported} && $self->{already_imported}->{$file_name} ? 1 : 0;
    }

    sub discardDuplicateFile {
        my ( $self, $file_name ) = @_;
        push @{ $self->{events} }, "discard:$file_name";
        die "discard failed for $file_name" if $self->{fail_discard};
        push @{ $self->{discarded} }, $file_name;
        return 1;
    }

    sub basketNameFromFile {
        my ( $self, $file_name ) = @_;
        return $self->{basket_names} && exists $self->{basket_names}->{$file_name}
            ? $self->{basket_names}->{$file_name}
            : 'duplicate-basket';
    }

    sub registerFileForImport {
        my ( $self, $file_name ) = @_;
        push @{ $self->{events} }, "register:$file_name";
        die "register failed for $file_name" if $self->{fail_register};
        push @{ $self->{registered} }, $file_name;
        return 1;
    }
}

{
    package Editx::TestContext;

    our $userenv;
    our $dbh;
    our @set_userenv_args;

    sub reset {
        $userenv = undef;
        $dbh = undef;
        @set_userenv_args = ();
        return 1;
    }

    sub userenv {
        return $userenv;
    }

    sub dbh {
        return $dbh;
    }

    sub set_dbh {
        my ( $class, $new_dbh ) = @_;
        $dbh = $new_dbh;
        return 1;
    }

    sub set_existing_userenv {
        my ( $class, $new_userenv ) = @_;
        $userenv = $new_userenv;
        return 1;
    }

    sub set_userenv {
        my ( $class, @args ) = @_;
        @set_userenv_args = @args;
        $userenv = {
            number      => $args[0],
            id          => $args[1],
            cardnumber  => $args[2],
            firstname   => $args[3],
            surname     => $args[4],
            branch      => $args[5],
            branchname  => $args[6],
            flags       => $args[7],
            emailaddress => $args[8],
            session_id  => $args[14],
        };
        return $userenv;
    }

    sub set_userenv_args {
        return [@set_userenv_args];
    }
}

{
    package Editx::TestDbh;

    sub new {
        my ( $class, %params ) = @_;
        return bless { hash_queries => [], array_queries => [], %params }, $class;
    }

    sub selectrow_hashref {
        my ( $self, $sql, $attrs, @bind ) = @_;
        push @{ $self->{hash_queries} }, [ $sql, @bind ];
        return $self->{patron};
    }

    sub selectrow_array {
        my ( $self, $sql, $attrs, @bind ) = @_;
        push @{ $self->{array_queries} }, [ $sql, @bind ];
        return $self->{branchname};
    }
}

{
    package Editx::TestParser;

    sub new {
        my ( $class, $events, $orders ) = @_;
        return bless { events => $events, orders => $orders, paths => [] }, $class;
    }

    sub parseFiles {
        my ( $self, $path ) = @_;
        push @{ $self->{paths} }, $path;
        push @{ $self->{events} }, "parse:$path";
        return %{ $self->{orders} };
    }

    sub parseFile {
        my ( $self, $path ) = @_;
        push @{ $self->{paths} }, $path;
        push @{ $self->{events} }, "parse-file:$path";
        return $self->{orders}->{$path};
    }
}

{
    package Editx::TestOrder;

    sub new {
        my ( $class, $id ) = @_;
        return bless { id => $id }, $class;
    }

    sub setFileName {
        my ( $self, $file_name ) = @_;
        $self->{file_name} = $file_name;
        return 1;
    }
}

{
    package Editx::TestOrderProcessor;

    sub new {
        my ( $class, $events, $params ) = @_;
        $params ||= {};
        return bless { events => $events, processed => [], %$params }, $class;
    }

    sub process {
        my ( $self, $order ) = @_;
        push @{ $self->{processed} }, $order;
        push @{ $self->{events} }, "process:$order";
        die "processing failed for $order" if $order eq 'bad-order';
        return 0 if $self->{return_false};
        return 1;
    }
}

{
    package Editx::TestTransactionManager;

    sub new {
        my ( $class, $events ) = @_;
        return bless { events => $events, transactions => [] }, $class;
    }

    sub begin {
        my ($self) = @_;
        push @{ $self->{events} }, 'txn_begin';
        my $transaction = Editx::TestTransaction->new( $self->{events} );
        push @{ $self->{transactions} }, $transaction;
        return $transaction;
    }
}

{
    package Editx::TestTransaction;

    sub new {
        my ( $class, $events ) = @_;
        return bless { events => $events, committed => 0, rolled_back => 0 }, $class;
    }

    sub commit {
        my ($self) = @_;
        push @{ $self->{events} }, 'txn_commit';
        $self->{committed} = 1;
        return 1;
    }

    sub rollback {
        my ($self) = @_;
        push @{ $self->{events} }, 'txn_rollback';
        $self->{rolled_back} = 1;
        return 1;
    }
}

my $settings = {
    settings => {
        log_directory       => '/tmp/editx-test-log',
        import_tmp_path     => '/tmp/editx/tmp',
        import_load_path    => '/tmp/editx/load',
        import_archive_path => '/tmp/editx/archive',
        import_failed_path  => '/tmp/editx/fail',
    },
};

subtest 'ensure_userenv keeps an existing Koha userenv' => sub {
    Editx::TestContext->reset;
    Editx::TestContext->set_existing_userenv( { number => 123 } );

    my $logger = Editx::TestLogger->new;
    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            context_class => 'Editx::TestContext',
        }
    );

    ok( $runner->ensure_userenv( { settings => { authoriser => 456 } }, $logger ), 'Existing userenv is accepted' );
    is_deeply( Editx::TestContext->set_userenv_args, [], 'Runner does not replace an existing Koha userenv' );
};

subtest 'ensure_userenv initializes cron imports from the configured authoriser' => sub {
    Editx::TestContext->reset;
    my $dbh = Editx::TestDbh->new(
        patron => {
            borrowernumber => 42,
            userid         => 'editxbot',
            cardnumber     => 'CARD42',
            firstname      => 'Editx',
            surname        => 'Bot',
            branchcode     => 'MAIN',
            flags          => 1,
            email          => 'editx@example.test',
        },
        branchname => 'Main Library',
    );
    Editx::TestContext->set_dbh($dbh);

    my $logger = Editx::TestLogger->new;
    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            context_class => 'Editx::TestContext',
        }
    );

    ok( $runner->ensure_userenv( { settings => { authoriser => 42 } }, $logger ), 'Runner initializes userenv' );
    is_deeply(
        Editx::TestContext->set_userenv_args,
        [
            42,
            'editxbot',
            'CARD42',
            'Editx',
            'Bot',
            'MAIN',
            'Main Library',
            1,
            'editx@example.test',
            undef,
            undef,
            undef,
            undef,
            undef,
            undef,
        ],
        'Runner builds the Koha userenv from the configured authoriser patron'
    );
    ok( !defined Editx::TestContext->userenv->{session_id}, 'Runner does not invent a web session id' );
    is( $dbh->{hash_queries}->[0]->[1], 42, 'Runner looks up the configured authoriser' );
    is( $dbh->{array_queries}->[0]->[1], 'MAIN', 'Runner looks up the authoriser branch name' );
    like(
        join( "\n", @{ $logger->messages } ),
        qr{Initialized Koha userenv for EDItX import using authoriser 42},
        'Runner logs the userenv initialization'
    );
};

subtest 'ensure_userenv fails early without an authoriser' => sub {
    Editx::TestContext->reset;

    my $logger = Editx::TestLogger->new;
    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            context_class => 'Editx::TestContext',
        }
    );

    my $ok = eval {
        $runner->ensure_userenv( { settings => {} }, $logger );
        1;
    };

    ok( !$ok, 'Runner refuses to import without an authoriser' );
    like( $@, qr{EDItX authoriser is not configured}, 'Runner reports a clear authoriser configuration error' );
};

subtest 'xml_schema_path is resolved from the installed plugin module location' => sub {
    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new;
    my $schema_path = $runner->xml_schema_path;

    like( $schema_path, qr{Koha/Plugin/Fi/KohaSuomi/Editx/Procurement/EditX/XmlSchema/?\z}, 'Runner uses the plugin-local XML schema directory' );
    ok( -d $schema_path, 'Resolved XML schema directory exists' );
    unlike( $schema_path, qr{\A/var/lib/koha/plugins/}, 'Runner does not hardcode the global plugin path without the Koha instance' );
};

subtest 'run queues, parses, validates, processes, and archives a file' => sub {
    my @events;
    my $logger = Editx::TestLogger->new;
    my $file_manager = Editx::TestFileManager->new( \@events );
    my $parser = Editx::TestParser->new( \@events, { '/tmp/editx/load/order.xml' => 'good-order' } );
    my $order_processor = Editx::TestOrderProcessor->new( \@events );
    my $transaction_manager = Editx::TestTransactionManager->new( \@events );
    my @validated;
    my @runtime_settings;

    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            settings        => $settings,
            logger          => $logger,
            file_manager    => $file_manager,
            parser          => $parser,
            order_processor => $order_processor,
            transaction_manager => $transaction_manager,
            validator       => sub {
                my ($file_name) = @_;
                push @validated, $file_name;
                push @events, "validate:$file_name";
                return 1;
            },
            runtime_logger => sub {
                my ($settings_arg) = @_;
                push @runtime_settings, $settings_arg;
                return 1;
            },
            userenv_initializer => sub {
                push @events, 'userenv';
                return 1;
            },
        }
    );

    my $result = $runner->run;

    is_deeply(
        $result,
        { processed => 1, failed => 0, skipped => 0 },
        'Runner returns processed and failed counters'
    );
    is_deeply( $parser->{paths}, [ '/tmp/editx/load' ], 'Runner parses the configured load path' );
    is_deeply( \@validated, [ '/tmp/editx/load/order.xml' ], 'Runner validates the parsed file path' );
    is_deeply( $file_manager->{checked_imported}, [ '/tmp/editx/load/order.xml' ], 'Runner checks import history before validation' );
    is_deeply( $order_processor->{processed}, ['good-order'], 'Runner sends the parsed order to the order processor' );
    is( scalar @{ $transaction_manager->{transactions} }, 1, 'Runner starts one transaction for the imported file' );
    is( $transaction_manager->{transactions}->[0]->{committed}, 1, 'Runner commits a successfully processed file' );
    is( $transaction_manager->{transactions}->[0]->{rolled_back}, 0, 'Runner does not roll back a successfully processed file' );
    is_deeply( $file_manager->{archived}, [ '/tmp/editx/load/order.xml' ], 'Runner archives a successfully processed file' );
    is_deeply( $file_manager->{failed}, [], 'Runner does not fail a successfully processed file' );
    is( scalar @runtime_settings, 1, 'Runner logs import settings once' );
    is_deeply(
        \@events,
        [
            'userenv',
            'fillLoadFolder',
            'parse:/tmp/editx/load',
            'validate:/tmp/editx/load/order.xml',
            'txn_begin',
            'process:good-order',
            'txn_commit',
            'archive:/tmp/editx/load/order.xml',
        ],
        'Runner commits the import before archiving the file'
    );
};

subtest 'run_file_paths imports selected staged files and reports preparation failures' => sub {
    my $tmp_dir = tempdir( CLEANUP => 1 );
    my $selected_file = File::Spec->catfile( $tmp_dir, 'selected.xml' );
    open my $fh, '>', $selected_file or die "Could not create $selected_file: $!";
    print {$fh} '<LibraryShipNotice />';
    close $fh or die "Could not close $selected_file: $!";
    my $missing_file = File::Spec->catfile( $tmp_dir, 'missing.xml' );

    my @events;
    my $logger = Editx::TestLogger->new;
    my $file_manager = Editx::TestFileManager->new( \@events );
    my $order = Editx::TestOrder->new('selected');
    my $parser = Editx::TestParser->new( \@events, { $selected_file => $order } );
    my $order_processor = Editx::TestOrderProcessor->new( \@events );
    my $transaction_manager = Editx::TestTransactionManager->new( \@events );
    my @validated;
    my @runtime_settings;

    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            settings              => $settings,
            logger                => $logger,
            file_manager          => $file_manager,
            parser                => $parser,
            order_processor       => $order_processor,
            transaction_manager   => $transaction_manager,
            validator             => sub {
                my ($file_name) = @_;
                push @validated, $file_name;
                push @events, "validate:$file_name";
                return 1;
            },
            runtime_logger        => sub {
                my ($settings_arg) = @_;
                push @runtime_settings, $settings_arg;
                return 1;
            },
            userenv_initializer   => sub {
                push @events, 'userenv';
                return 1;
            },
        }
    );

    my $result = $runner->run_file_paths( [ $selected_file, $missing_file ] );

    is_deeply(
        { map { $_ => $result->{$_} } qw(processed failed skipped) },
        { processed => 1, failed => 1, skipped => 0 },
        'Runner imports selected staged files and counts preparation failures'
    );
    is_deeply( $file_manager->{registered}, [$selected_file], 'Runner registers existing selected files before parsing' );
    is_deeply( $parser->{paths}, [$selected_file], 'Runner parses only the selected file that exists' );
    is( $order->{file_name}, 'selected.xml', 'Runner keeps the original downloaded basename on the parsed order' );
    is_deeply( \@validated, [$selected_file], 'Runner validates the selected staged file before processing' );
    is_deeply( $order_processor->{processed}, [$order], 'Runner sends the selected parsed order to the processor' );
    is( scalar @{ $transaction_manager->{transactions} }, 1, 'Runner starts one transaction for the selected import' );
    is( $transaction_manager->{transactions}->[0]->{committed}, 1, 'Runner commits the selected import' );
    is_deeply( $file_manager->{archived}, [$selected_file], 'Runner archives the selected file after processing' );
    is_deeply( $file_manager->{failed}, [$missing_file], 'Runner moves missing selected files through the fail path' );
    is( $result->{errors}->[0]->{file}, $missing_file, 'Runner reports the missing selected file path' );
    like( $result->{errors}->[0]->{error}, qr{Selected EDItX file does not exist}, 'Runner reports a clear preparation error' );
    is( scalar @runtime_settings, 1, 'Runner logs selected import settings once' );
    like(
        join( "\n", @{ $logger->messages } ),
        qr{Selected EDItX file \Q$missing_file\E could not be prepared for import},
        'Runner logs the selected-file preparation failure'
    );
};

subtest 'run reports duplicate files skipped during tmp-to-load staging' => sub {
    my @events;
    my $file_manager = Editx::TestFileManager->new(
        \@events,
        {
            fill_result => { staged => 0, skipped => 5, postponed => 0 },
        }
    );
    my $parser = Editx::TestParser->new( \@events, {} );
    my $logger = Editx::TestLogger->new;
    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            settings        => $settings,
            logger          => $logger,
            file_manager    => $file_manager,
            parser          => $parser,
            order_processor => Editx::TestOrderProcessor->new( \@events ),
            runtime_logger  => sub {
                return 1;
            },
            userenv_initializer => sub {
                push @events, 'userenv';
                return 1;
            },
        }
    );

    my $result = $runner->run;

    is_deeply(
        { map { $_ => $result->{$_} } qw(processed failed skipped) },
        { processed => 0, failed => 0, skipped => 5 },
        'Runner includes duplicate files skipped before parser sees the load folder'
    );
    like(
        join( "\n", @{ $logger->messages } ),
        qr{Ended Koha::Plugin::Fi::KohaSuomi::Editx::Procurement: processed 0, failed 0, skipped 5},
        'Runner logs the staging skipped count in the final cron summary'
    );
    is_deeply( \@events, [ 'userenv', 'fillLoadFolder', 'parse:/tmp/editx/load' ], 'Runner still parses the load folder after staging' );
};

subtest 'run_file_paths can suppress console echo for direct web imports' => sub {
    my $tmp_dir = tempdir( CLEANUP => 1 );
    my $selected_file = File::Spec->catfile( $tmp_dir, 'selected.xml' );
    open my $fh, '>', $selected_file or die "Could not create $selected_file: $!";
    print {$fh} '<LibraryShipNotice />';
    close $fh or die "Could not close $selected_file: $!";

    my @events;
    my $logger = Editx::TestLogger->new;
    my $file_manager = Editx::TestFileManager->new( \@events );
    my $order = Editx::TestOrder->new('selected');
    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            echo                => 0,
            settings            => $settings,
            logger              => $logger,
            file_manager        => $file_manager,
            parser              => Editx::TestParser->new( \@events, { $selected_file => $order } ),
            order_processor     => Editx::TestOrderProcessor->new( \@events ),
            transaction_manager => Editx::TestTransactionManager->new( \@events ),
            validator           => sub { return 1; },
            runtime_logger      => sub { return 1; },
            userenv_initializer => sub { return 1; },
        }
    );

    my $result = $runner->run_file_paths( [$selected_file] );

    is( $result->{processed}, 1, 'Selected web-style import still processes the file' );
    my @echo_values = grep { defined $_ } @{ $logger->echoes };
    is_deeply( \@echo_values, [ 0, 0 ], 'Selected web-style import does not echo start/end messages to STDOUT' );
};

subtest 'process_orders moves a failing file to the fail folder' => sub {
    my @events;
    my $logger = Editx::TestLogger->new;
    my $file_manager = Editx::TestFileManager->new( \@events );
    my $order_processor = Editx::TestOrderProcessor->new( \@events );
    my $transaction_manager = Editx::TestTransactionManager->new( \@events );
    my @validated;

    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            logger          => $logger,
            file_manager    => $file_manager,
            order_processor => $order_processor,
            transaction_manager => $transaction_manager,
            validator       => sub {
                my ($file_name) = @_;
                push @validated, $file_name;
                push @events, "validate:$file_name";
                return 1;
            },
        }
    );

    my $result = $runner->process_orders( { '/tmp/editx/load/bad.xml' => 'bad-order' } );

    is_deeply(
        { map { $_ => $result->{$_} } qw(processed failed skipped) },
        { processed => 0, failed => 1, skipped => 0 },
        'Runner counts a processing failure'
    );
    is( $result->{errors}->[0]->{file}, '/tmp/editx/load/bad.xml', 'Runner records the failed file path' );
    like( $result->{errors}->[0]->{error}, qr{processing failed for bad-order}, 'Runner records the processing error' );
    is_deeply( \@validated, [ '/tmp/editx/load/bad.xml' ], 'Runner validates before processing a failing file' );
    is( scalar @{ $transaction_manager->{transactions} }, 1, 'Runner starts one transaction for the failing file' );
    is( $transaction_manager->{transactions}->[0]->{committed}, 0, 'Runner does not commit a failing file' );
    is( $transaction_manager->{transactions}->[0]->{rolled_back}, 1, 'Runner rolls back a failing file' );
    is_deeply( $file_manager->{archived}, [], 'Runner does not archive a failing file' );
    is_deeply( $file_manager->{failed}, [ '/tmp/editx/load/bad.xml' ], 'Runner moves a failing file to fail folder' );
    is_deeply(
        \@events,
        [
            'validate:/tmp/editx/load/bad.xml',
            'txn_begin',
            'process:bad-order',
            'txn_rollback',
            'fail:/tmp/editx/load/bad.xml',
        ],
        'Runner rolls back before moving the failed file'
    );
    like(
        join( "\n", @{ $logger->messages } ),
        qr{Order processing failed for file  /tmp/editx/load/bad\.xml},
        'Runner logs the existing failure message'
    );
};

subtest 'process_orders treats a false processor return as a failed import' => sub {
    my @events;
    my $logger = Editx::TestLogger->new;
    my $file_manager = Editx::TestFileManager->new( \@events );
    my $order_processor = Editx::TestOrderProcessor->new( \@events, { return_false => 1 } );
    my $transaction_manager = Editx::TestTransactionManager->new( \@events );

    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            logger              => $logger,
            file_manager        => $file_manager,
            order_processor     => $order_processor,
            transaction_manager => $transaction_manager,
            validator           => sub {
                my ($file_name) = @_;
                push @events, "validate:$file_name";
                return 1;
            },
        }
    );

    my $result = $runner->process_orders( { '/tmp/editx/load/false.xml' => 'false-order' } );

    is_deeply(
        { map { $_ => $result->{$_} } qw(processed failed skipped) },
        { processed => 0, failed => 1, skipped => 0 },
        'Runner counts a false processor return as failed'
    );
    is( $result->{errors}->[0]->{file}, '/tmp/editx/load/false.xml', 'Runner records the false processor file path' );
    like( $result->{errors}->[0]->{error}, qr{EDItX order processor returned false for file /tmp/editx/load/false\.xml}, 'Runner records the false processor error' );
    is( $transaction_manager->{transactions}->[0]->{committed}, 0, 'Runner does not commit a false processor result' );
    is( $transaction_manager->{transactions}->[0]->{rolled_back}, 1, 'Runner rolls back a false processor result' );
    is_deeply( $file_manager->{failed}, [ '/tmp/editx/load/false.xml' ], 'Runner moves a false processor result to fail folder' );
    like(
        join( "\n", @{ $logger->messages } ),
        qr{EDItX order processor returned false for file /tmp/editx/load/false\.xml},
        'Runner logs the false processor result'
    );
};

subtest 'process_orders treats archive failures as failed imports' => sub {
    my @events;
    my $logger = Editx::TestLogger->new;
    my $file_manager = Editx::TestFileManager->new( \@events, { fail_archive => 1 } );
    my $order_processor = Editx::TestOrderProcessor->new( \@events );
    my $transaction_manager = Editx::TestTransactionManager->new( \@events );
    my @validated;

    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            logger              => $logger,
            file_manager        => $file_manager,
            order_processor     => $order_processor,
            transaction_manager => $transaction_manager,
            validator           => sub {
                my ($file_name) = @_;
                push @validated, $file_name;
                push @events, "validate:$file_name";
                return 1;
            },
        }
    );

    my $result = $runner->process_orders( { '/tmp/editx/load/archive.xml' => 'good-order' } );

    is_deeply(
        { map { $_ => $result->{$_} } qw(processed failed skipped) },
        { processed => 0, failed => 1, skipped => 0 },
        'Runner counts an archive failure as a failed import'
    );
    is( $result->{errors}->[0]->{file}, '/tmp/editx/load/archive.xml', 'Runner records the archive failure file path' );
    like( $result->{errors}->[0]->{error}, qr{archive failed for /tmp/editx/load/archive\.xml}, 'Runner records the archive failure error' );
    is( $transaction_manager->{transactions}->[0]->{committed}, 1, 'Runner commits order processing before archive' );
    is( $transaction_manager->{transactions}->[0]->{rolled_back}, 0, 'Runner cannot roll back after archive failure' );
    is_deeply( $file_manager->{archived}, [], 'Runner does not mark the file as archived when archive dies' );
    is_deeply( $file_manager->{failed}, [ '/tmp/editx/load/archive.xml' ], 'Runner moves an archive failure to fail folder' );
    is_deeply(
        \@events,
        [
            'validate:/tmp/editx/load/archive.xml',
            'txn_begin',
            'process:good-order',
            'txn_commit',
            'archive:/tmp/editx/load/archive.xml',
            'fail:/tmp/editx/load/archive.xml',
        ],
        'Runner moves archive failures to fail after commit'
    );
    like(
        join( "\n", @{ $logger->messages } ),
        qr{archive failed for /tmp/editx/load/archive\.xml},
        'Runner logs the archive failure'
    );
};

subtest 'process_orders logs fail-folder move failures without hiding the original error' => sub {
    my @events;
    my $logger = Editx::TestLogger->new;
    my $file_manager = Editx::TestFileManager->new( \@events, { fail_move => 1 } );
    my $order_processor = Editx::TestOrderProcessor->new( \@events );
    my $transaction_manager = Editx::TestTransactionManager->new( \@events );

    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            logger              => $logger,
            file_manager        => $file_manager,
            order_processor     => $order_processor,
            transaction_manager => $transaction_manager,
            validator           => sub {
                my ($file_name) = @_;
                push @events, "validate:$file_name";
                return 1;
            },
        }
    );

    my $result = $runner->process_orders( { '/tmp/editx/load/stuck.xml' => 'bad-order' } );
    my $messages = join( "\n", @{ $logger->messages } );

    is_deeply(
        { map { $_ => $result->{$_} } qw(processed failed skipped) },
        { processed => 0, failed => 1, skipped => 0 },
        'Runner still counts the import as failed when the fail move fails'
    );
    is( $result->{errors}->[0]->{file}, '/tmp/editx/load/stuck.xml', 'Runner records the stuck file path' );
    like( $result->{errors}->[0]->{error}, qr{processing failed for bad-order}, 'Runner records the original processing error' );
    is_deeply( $file_manager->{failed}, [], 'Runner does not mark the file as failed when fail move dies' );
    is_deeply(
        \@events,
        [
            'validate:/tmp/editx/load/stuck.xml',
            'txn_begin',
            'process:bad-order',
            'txn_rollback',
            'fail:/tmp/editx/load/stuck.xml',
        ],
        'Runner attempts the fail move after rollback'
    );
    like(
        $messages,
        qr{Could not move failed EDItX file /tmp/editx/load/stuck\.xml to the fail folder\.},
        'Runner logs the fail-folder move failure'
    );
    like(
        $messages,
        qr{processing failed for bad-order},
        'Runner keeps logging the original processing error'
    );
};

subtest 'process_orders skips and discards an already imported file' => sub {
    my @events;
    my $logger = Editx::TestLogger->new;
    my $file_name = '/tmp/editx/load/duplicate.xml';
    my $file_manager = Editx::TestFileManager->new( \@events, { already_imported => { $file_name => 1 } } );
    my $order_processor = Editx::TestOrderProcessor->new( \@events );
    my $transaction_manager = Editx::TestTransactionManager->new( \@events );
    my @validated;

    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            logger              => $logger,
            file_manager        => $file_manager,
            order_processor     => $order_processor,
            transaction_manager => $transaction_manager,
            validator           => sub {
                my ($validated_file_name) = @_;
                push @validated, $validated_file_name;
                push @events, "validate:$validated_file_name";
                return 1;
            },
        }
    );

    my $result = $runner->process_orders( { $file_name => 'good-order' } );

    is_deeply(
        { map { $_ => $result->{$_} } qw(processed failed skipped) },
        { processed => 0, failed => 0, skipped => 1 },
        'Runner counts an already imported file as skipped'
    );
    is_deeply(
        $result->{skipped_files},
        [
            {
                file        => $file_name,
                reason      => 'already_imported',
                basket_name => 'duplicate-basket',
                message     => "Skipping already imported EDItX file $file_name.",
            }
        ],
        'Runner reports the skipped duplicate file reason'
    );
    is_deeply( \@validated, [], 'Runner does not validate an already imported file' );
    is_deeply( $order_processor->{processed}, [], 'Runner does not process an already imported file' );
    is_deeply( $transaction_manager->{transactions}, [], 'Runner does not start a transaction for an already imported file' );
    is_deeply( $file_manager->{discarded}, [$file_name], 'Runner discards an already imported file' );
    is_deeply( $file_manager->{archived}, [], 'Runner does not archive an already imported file' );
    is_deeply( $file_manager->{failed}, [], 'Runner does not fail an already imported file' );
    is_deeply( \@events, ["discard:$file_name"], 'Runner only discards an already imported file' );
    like(
        join( "\n", @{ $logger->messages } ),
        qr{Skipping already imported EDItX file /tmp/editx/load/duplicate\.xml},
        'Runner logs the duplicate skip'
    );
};

done_testing();

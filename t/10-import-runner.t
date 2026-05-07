#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
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
    package Editx::TestFileManager;

    sub new {
        my ( $class, $events ) = @_;
        return bless { events => $events, archived => [], failed => [] }, $class;
    }

    sub fillLoadFolder {
        my ($self) = @_;
        push @{ $self->{events} }, 'fillLoadFolder';
        return 1;
    }

    sub archiveFile {
        my ( $self, $file_name ) = @_;
        push @{ $self->{archived} }, $file_name;
        push @{ $self->{events} }, "archive:$file_name";
        return 1;
    }

    sub moveToFailFolder {
        my ( $self, $file_name ) = @_;
        push @{ $self->{failed} }, $file_name;
        push @{ $self->{events} }, "fail:$file_name";
        return 1;
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
}

{
    package Editx::TestOrderProcessor;

    sub new {
        my ( $class, $events ) = @_;
        return bless { events => $events, processed => [] }, $class;
    }

    sub process {
        my ( $self, $order ) = @_;
        push @{ $self->{processed} }, $order;
        push @{ $self->{events} }, "process:$order";
        die "processing failed for $order" if $order eq 'bad-order';
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

subtest 'run queues, parses, validates, processes, and archives a file' => sub {
    my @events;
    my $logger = Editx::TestLogger->new;
    my $file_manager = Editx::TestFileManager->new( \@events );
    my $parser = Editx::TestParser->new( \@events, { '/tmp/editx/load/order.xml' => 'good-order' } );
    my $order_processor = Editx::TestOrderProcessor->new( \@events );
    my @validated;
    my @runtime_settings;

    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            settings        => $settings,
            logger          => $logger,
            file_manager    => $file_manager,
            parser          => $parser,
            order_processor => $order_processor,
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
        }
    );

    my $result = $runner->run;

    is_deeply(
        $result,
        { processed => 1, failed => 0 },
        'Runner returns processed and failed counters'
    );
    is_deeply( $parser->{paths}, [ '/tmp/editx/load' ], 'Runner parses the configured load path' );
    is_deeply( \@validated, [ '/tmp/editx/load/order.xml' ], 'Runner validates the parsed file path' );
    is_deeply( $order_processor->{processed}, ['good-order'], 'Runner sends the parsed order to the order processor' );
    is_deeply( $file_manager->{archived}, [ '/tmp/editx/load/order.xml' ], 'Runner archives a successfully processed file' );
    is_deeply( $file_manager->{failed}, [], 'Runner does not fail a successfully processed file' );
    is( scalar @runtime_settings, 1, 'Runner logs import settings once' );
    is_deeply(
        \@events,
        [
            'fillLoadFolder',
            'parse:/tmp/editx/load',
            'validate:/tmp/editx/load/order.xml',
            'process:good-order',
            'archive:/tmp/editx/load/order.xml',
        ],
        'Runner keeps the current import operation order'
    );
};

subtest 'process_orders moves a failing file to the fail folder' => sub {
    my @events;
    my $logger = Editx::TestLogger->new;
    my $file_manager = Editx::TestFileManager->new( \@events );
    my $order_processor = Editx::TestOrderProcessor->new( \@events );
    my @validated;

    my $runner = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new(
        {
            logger          => $logger,
            file_manager    => $file_manager,
            order_processor => $order_processor,
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
        $result,
        { processed => 0, failed => 1 },
        'Runner counts a processing failure'
    );
    is_deeply( \@validated, [ '/tmp/editx/load/bad.xml' ], 'Runner validates before processing a failing file' );
    is_deeply( $file_manager->{archived}, [], 'Runner does not archive a failing file' );
    is_deeply( $file_manager->{failed}, [ '/tmp/editx/load/bad.xml' ], 'Runner moves a failing file to fail folder' );
    like(
        join( "\n", @{ $logger->messages } ),
        qr{Order processing failed for file  /tmp/editx/load/bad\.xml},
        'Runner logs the existing failure message'
    );
};

done_testing();

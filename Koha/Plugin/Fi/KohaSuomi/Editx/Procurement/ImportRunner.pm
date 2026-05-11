#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner;

use Modern::Perl;
use File::Basename qw(basename dirname);
use File::Spec;
use Try::Tiny;

sub new {
    my ( $class, $params ) = @_;

    $params ||= {};

    return bless { %$params }, $class;
}

sub run {
    my ($self) = @_;

    my $settings = $self->settings;
    my $logger = $self->logger;

    $logger->info( "Started Koha::Procurement", 1 );
    $self->_log_import_settings($settings);
    $self->ensure_userenv( $settings, $logger );

    my $file_manager = $self->file_manager;
    my $parser = $self->parser;
    my $order_processor = $self->order_processor;
    my $library_ship_notice_path = $settings->{settings}->{import_load_path};

    my $staging_result = $file_manager->fillLoadFolder();
    my %orders = $parser->parseFiles($library_ship_notice_path);
    $logger->info( "EDItX parser returned " . scalar( keys %orders ) . " order file(s)." );

    my $result = $self->process_orders( \%orders, $file_manager, $order_processor, $logger );
    if ( ref $staging_result eq 'HASH' ) {
        $result->{skipped} += $staging_result->{skipped} || 0;
    }

    if ( !$result->{processed} && !$result->{failed} && !$result->{skipped} ) {
        $logger->info("No EDItX order files found for processing.");
    }

    $logger->info(
        "Ended Koha::Plugin::Fi::KohaSuomi::Editx::Procurement: processed $result->{processed}, failed $result->{failed}, skipped $result->{skipped}.",
        1
    );

    return $result;
}

sub run_file_paths {
    my ( $self, $file_paths ) = @_;

    $file_paths ||= [];

    my $settings = $self->settings;
    my $logger = $self->logger;

    my $echo = $self->echo_logs;
    $logger->info( 'Started selected EDItX import', $echo );
    $self->_log_import_settings($settings);
    $self->ensure_userenv( $settings, $logger );

    my $file_manager = $self->file_manager;
    my $parser = $self->parser;
    my $order_processor = $self->order_processor;

    my %orders;
    my ( $failed, @errors ) = ( 0 );
    for my $file_path (@$file_paths) {
        try {
            die "Selected EDItX file does not exist: $file_path\n" if !-f $file_path;
            $file_manager->registerFileForImport($file_path);

            my $order = $parser->parseFile($file_path);
            die "Could not parse EDItX file $file_path into an order object.\n" if !$order;
            $order->setFileName( basename($file_path) ) if $order->can('setFileName');
            $orders{$file_path} = $order;
        } catch {
            my $error = $_;
            $self->_move_failed_file( $file_manager, $file_path, $logger );
            $failed++;
            push @errors, {
                file  => $file_path,
                error => "$error",
            };
            $logger->warn("Selected EDItX file $file_path could not be prepared for import.");
            $logger->logError("Error was: $error");
        };
    }

    my $result = $self->process_orders( \%orders, $file_manager, $order_processor, $logger );
    $result->{failed} += $failed;
    push @{ $result->{errors} ||= [] }, @errors if @errors;

    $logger->info(
        "Ended selected EDItX import: processed $result->{processed}, failed $result->{failed}, skipped $result->{skipped}.",
        $echo
    );

    return $result;
}

sub ensure_userenv {
    my ( $self, $settings, $logger ) = @_;

    if ( my $initializer = $self->{userenv_initializer} ) {
        return $initializer->( $settings, $logger, $self );
    }

    my $context_class = $self->context_class;
    return 1 if $context_class->userenv;

    $settings ||= {};
    my $authoriser = $settings->{settings} ? $settings->{settings}->{authoriser} : undef;
    if ( !defined $authoriser || $authoriser !~ /\A[0-9]+\z/ ) {
        die "EDItX authoriser is not configured; cannot initialize Koha userenv for cron/manual import.\n";
    }

    my $dbh = $context_class->dbh;
    my $patron = $dbh->selectrow_hashref(
        q{
            SELECT borrowernumber, userid, cardnumber, firstname, surname, branchcode, flags, email
            FROM borrowers
            WHERE borrowernumber = ?
        },
        undef,
        $authoriser
    );

    if ( !$patron ) {
        die "EDItX authoriser borrowernumber $authoriser does not exist; cannot initialize Koha userenv.\n";
    }

    my ($branchname) = $dbh->selectrow_array(
        q{
            SELECT branchname
            FROM branches
            WHERE branchcode = ?
        },
        undef,
        $patron->{branchcode}
    );

    $context_class->set_userenv(
        $patron->{borrowernumber},
        $patron->{userid},
        $patron->{cardnumber},
        $patron->{firstname},
        $patron->{surname},
        $patron->{branchcode},
        $branchname // q{},
        $patron->{flags},
        $patron->{email},
        undef,
        undef,
        undef,
        undef,
        undef,
        undef
    );

    $logger->info("Initialized Koha userenv for EDItX import using authoriser $authoriser.");

    return 1;
}

sub context_class {
    my ($self) = @_;

    return $self->{context_class} if $self->{context_class};

    require C4::Context;
    return 'C4::Context';
}

sub process_orders {
    my ( $self, $orders, $file_manager, $order_processor, $logger ) = @_;

    $orders ||= {};
    $file_manager ||= $self->file_manager;
    $order_processor ||= $self->order_processor;
    $logger ||= $self->logger;

    my $processed = 0;
    my $failed = 0;
    my $skipped = 0;
    my @errors;
    my @skipped_files;

    while ( my ( $file_name, $order ) = each %$orders ) {
        try {
            $logger->info("Started processing order from file $file_name");

            if ( my $skipped_file = $self->_skip_already_imported_file( $file_manager, $file_name, $logger ) ) {
                $skipped++;
                push @skipped_files, $skipped_file;
            } else {

                $self->validate_editx($file_name);
                $self->_process_order_in_transaction( $file_name, $order, $order_processor, $logger );
                $file_manager->archiveFile($file_name);
                $processed++;

                $logger->info("Ended processing order from file $file_name");
            }
        } catch {
            my $error = $_;
            $self->_move_failed_file( $file_manager, $file_name, $logger );
            $failed++;
            my $fail_message = "Order processing failed for file  $file_name.";
            push @errors, {
                file  => $file_name,
                error => "$error",
            };
            $logger->warn($fail_message);
            $logger->logError($fail_message);
            $logger->logError("Error was: $error");
        };
    }

    return {
        processed => $processed,
        failed    => $failed,
        skipped   => $skipped,
        @errors ? ( errors => \@errors ) : (),
        @skipped_files ? ( skipped_files => \@skipped_files ) : (),
    };
}

sub _skip_already_imported_file {
    my ( $self, $file_manager, $file_name, $logger ) = @_;

    return if !$file_manager->filePathAlreadyImported($file_name);

    my $message = "Skipping already imported EDItX file $file_name.";
    my $basket_name = eval { $file_manager->basketNameFromFile($file_name) };
    $basket_name = '' if !defined $basket_name || $@;

    $logger->warn($message);
    $file_manager->discardDuplicateFile($file_name);

    return {
        file        => $file_name,
        reason      => 'already_imported',
        basket_name => $basket_name,
        message     => $message,
    };
}

sub _process_order_in_transaction {
    my ( $self, $file_name, $order, $order_processor, $logger ) = @_;

    my $transaction = $self->transaction_manager->begin;

    try {
        my $processed = $order_processor->process($order);
        die "EDItX order processor returned false for file $file_name.\n" if !$processed;
        $transaction->commit;
    } catch {
        my $error = $_;
        $self->_rollback_transaction( $transaction, $logger, $file_name );
        die $error;
    };

    return 1;
}

sub _rollback_transaction {
    my ( $self, $transaction, $logger, $file_name ) = @_;

    return if !$transaction;

    try {
        $transaction->rollback;
    } catch {
        my $rollback_error = $_;
        my $fail_message = "Rollback failed for EDItX file $file_name: $rollback_error";
        $logger->warn($fail_message);
        $logger->logError($fail_message);
    };

    return;
}

sub _move_failed_file {
    my ( $self, $file_manager, $file_name, $logger ) = @_;

    try {
        $file_manager->moveToFailFolder($file_name);
    } catch {
        my $error = $_;
        my $fail_message = "Could not move failed EDItX file $file_name to the fail folder.";
        $logger->warn($fail_message);
        $logger->logError($fail_message);
        $logger->logError("Error was: $error");
    };

    return;
}

sub settings {
    my ($self) = @_;

    return $self->{settings} if $self->{settings};

    $self->{settings} = $self->config->getSettings();

    return $self->{settings};
}

sub config {
    my ($self) = @_;

    return $self->{config} if $self->{config};

    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;
    $self->{config} = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config->new;

    return $self->{config};
}

sub logger {
    my ($self) = @_;

    return $self->{logger} if $self->{logger};

    my $settings = $self->settings;
    my $log_path = $settings->{settings}->{log_directory};
    die('The log_directory not set in config.') unless defined $log_path;

    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger;
    $self->{logger} = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger->new($log_path);

    return $self->{logger};
}

sub file_manager {
    my ($self) = @_;

    return $self->{file_manager} if $self->{file_manager};

    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File;
    $self->{file_manager} = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File->new;

    return $self->{file_manager};
}

sub parser {
    my ($self) = @_;

    return $self->{parser} if $self->{parser};

    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::Parser;
    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::ObjectFactory::LibraryShipNotice;

    $self->{parser} = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::Parser->new((
        objectFactory => Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::ObjectFactory::LibraryShipNotice->new((
            schemaPath => $self->xml_schema_path,
        )),
    ));

    return $self->{parser};
}

sub xml_schema_path {
    my ($self) = @_;

    return $self->{schema_path} if $self->{schema_path};

    my $module_path = $INC{'Koha/Plugin/Fi/KohaSuomi/Editx/Procurement/ImportRunner.pm'};
    die 'Could not locate EDItX ImportRunner module path.' unless $module_path;

    my $procurement_path = dirname($module_path);
    my $schema_path = File::Spec->catdir( $procurement_path, 'EditX', 'XmlSchema' );
    die "EDItX XML schema path does not exist: $schema_path" unless -d $schema_path;

    $self->{schema_path} = File::Spec->catdir($schema_path, q{});

    return $self->{schema_path};
}

sub order_processor {
    my ($self) = @_;

    return $self->{order_processor} if $self->{order_processor};

    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor;
    $self->{order_processor} = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor->new;

    return $self->{order_processor};
}

sub transaction_manager {
    my ($self) = @_;

    return $self->{transaction_manager} if $self->{transaction_manager};

    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::TransactionManager;
    $self->{transaction_manager} = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::TransactionManager->new;

    return $self->{transaction_manager};
}

sub validate_editx {
    my ( $self, $file_name ) = @_;

    if ( my $validator = $self->{validator} ) {
        return $validator->($file_name);
    }

    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator;
    return Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::validateEditx($file_name);
}

sub echo_logs {
    my ($self) = @_;

    return exists $self->{echo} ? $self->{echo} ? 1 : 0 : 1;
}

sub _log_import_settings {
    my ( $self, $settings ) = @_;

    if ( my $runtime_logger = $self->{runtime_logger} ) {
        return $runtime_logger->($settings);
    }

    require Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog;
    return Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->log(
        {
            level     => 'debug',
            message   => 'EDItX import configuration loaded',
            component => 'import',
            context   => {
                import_tmp_path     => $settings->{settings}->{import_tmp_path},
                import_load_path    => $settings->{settings}->{import_load_path},
                import_archive_path => $settings->{settings}->{import_archive_path},
                import_failed_path  => $settings->{settings}->{import_failed_path},
            },
        }
    );
}

1;

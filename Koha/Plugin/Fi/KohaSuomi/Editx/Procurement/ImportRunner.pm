#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner;

use Modern::Perl;
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

    my $file_manager = $self->file_manager;
    my $parser = $self->parser;
    my $order_processor = $self->order_processor;
    my $library_ship_notice_path = $settings->{settings}->{import_load_path};

    $file_manager->fillLoadFolder();
    my %orders = $parser->parseFiles($library_ship_notice_path);
    $logger->info( "EDItX parser returned " . scalar( keys %orders ) . " order file(s)." );

    my $result = $self->process_orders( \%orders, $file_manager, $order_processor, $logger );

    if ( !$result->{processed} && !$result->{failed} && !$result->{skipped} ) {
        $logger->info("No EDItX order files found for processing.");
    }

    $logger->info(
        "Ended Koha::Plugin::Fi::KohaSuomi::Editx::Procurement: processed $result->{processed}, failed $result->{failed}, skipped $result->{skipped}.",
        1
    );

    return $result;
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

    while ( my ( $file_name, $order ) = each %$orders ) {
        try {
            $logger->info("Started processing order from file $file_name");

            if ( $self->_skip_already_imported_file( $file_manager, $file_name, $logger ) ) {
                $skipped++;
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
            $logger->warn($fail_message);
            $logger->logError($fail_message);
            $logger->logError("Error was: $error");
        };
    }

    return {
        processed => $processed,
        failed    => $failed,
        skipped   => $skipped,
    };
}

sub _skip_already_imported_file {
    my ( $self, $file_manager, $file_name, $logger ) = @_;

    return 0 if !$file_manager->filePathAlreadyImported($file_name);

    my $message = "Skipping already imported EDItX file $file_name.";
    $logger->warn($message);
    $file_manager->discardDuplicateFile($file_name);

    return 1;
}

sub _process_order_in_transaction {
    my ( $self, $file_name, $order, $order_processor, $logger ) = @_;

    my $transaction = $self->transaction_manager->begin;

    try {
        $order_processor->process($order);
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
            schemaPath => '/var/lib/koha/plugins/Koha/Plugin/Fi/KohaSuomi/Editx/Procurement/EditX/XmlSchema/',
        )),
    ));

    return $self->{parser};
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

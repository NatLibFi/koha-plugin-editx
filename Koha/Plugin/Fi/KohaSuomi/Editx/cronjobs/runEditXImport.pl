#!/usr/bin/perl

use strict;
use warnings;
use Modern::Perl;
use Try::Tiny;
use Data::Dumper;

use Koha::Plugins;
use Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::Parser;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::ObjectFactory::LibraryShipNotice;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::BranchLocationYear::Parser;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator;

my $config = new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;
my $settings = $config->getSettings();
my $logPath;

if(defined $settings->{'settings'}->{'log_directory'}){
    $logPath = $settings->{'settings'}->{'log_directory'};
}
else{
    die('The log_directory not set in config.');
}

my $fileManager = new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File;
my $logger = new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger($logPath);
my $orderProcessor = new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor;

$logger->info("Started Koha::Procurement",1);
Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->log(
    {
        level     => 'debug',
        message   => 'EDItX import configuration loaded',
        component => 'import',
        context   => {
            import_tmp_path     => $settings->{'settings'}->{'import_tmp_path'},
            import_load_path    => $settings->{'settings'}->{'import_load_path'},
            import_archive_path => $settings->{'settings'}->{'import_archive_path'},
            import_failed_path  => $settings->{'settings'}->{'import_failed_path'},
        },
    }
);

my $parser = new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::Parser((
    'objectFactory', new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::ObjectFactory::LibraryShipNotice((
            'schemaPath','/var/lib/koha/plugins/Koha/Plugin/Fi/KohaSuomi/Editx/Procurement/EditX/XmlSchema/'
        ))
    ));

my %orders;
my $libraryShipNoticePath;

if(defined $settings->{'settings'}->{'import_load_path'}){
    $libraryShipNoticePath = $settings->{'settings'}->{'import_load_path'};
}

$fileManager->fillLoadFolder();
%orders = $parser->parseFiles($libraryShipNoticePath);
$logger->info("EDItX parser returned " . scalar( keys %orders ) . " order file(s).");

my $fileName;
my $order;
my $processed = 0;
my $failed = 0;
if(%orders){
    while ( ($fileName, $order) = each %orders )
    {
       try{ 
            $logger->info("Started processing order from file $fileName");
            Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::validateEditx($fileName);

            # I am old and obsolete $orderProcessor->startProcessing();
            $orderProcessor->process($order);
            # I am old and obsolete $orderProcessor->endProcessing();
            $fileManager->archiveFile($fileName);
            $processed++;

            $logger->info("Ended processing order from file $fileName");
        }
        catch{
            # I am old and obsolete $orderProcessor->rollBack();
            $fileManager->moveToFailFolder($fileName);
            $failed++;
            my $failMsq = "Order processing failed for file  $fileName.";
            $logger->warn($failMsq);
            $logger->logError($failMsq);
            $logger->logError("Error was: $_");
        }
    }
} else {
    $logger->info("No EDItX order files found for processing.");
}
$logger->info("Ended Koha::Plugin::Fi::KohaSuomi::Editx::Procurement: processed $processed, failed $failed.",1);

#!/usr/bin/perl

package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator;

use strict;
use Modern::Perl;
use XML::LibXML;
use XML::LibXML::XPathContext;
use MARC::Record;
use C4::Record qw( marc2marc marc2marcxml marcxml2marc marc2dcxml marc2modsxml marc2bibtex );

use Koha::Plugins;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File;

#use File::Slurp;
#use Encode;

use utf8;
use open ':std', ':encoding(UTF-8)';
use Getopt::Long;
use Try::Tiny;
use File::Basename;

sub validateEditx {
    
  my $filename = shift;

  my $fileforlog = basename($filename) . ": ";

  my $parser = XML::LibXML->new();
  my $doc    = XML::LibXML->load_xml(location => $filename);
  my $xc     = XML::LibXML::XPathContext->new($doc);

  my $errors = 0;

  my $config   = new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;
  my $settings = $config->getSettings();
  my $logPath;

  if (defined $settings->{'settings'}->{'log_directory'}) {
    $logPath = $settings->{'settings'}->{'log_directory'};
  } else {
    die('The log_directory not set in config.');
  }

  my $logger = new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger($logPath);

    #Validate against LibraryShipNotice v1.0 Schema
    #$xc->registerNs('acs', "http://openncip.org/acs-config/1.0/");

    #my $parser = XML::LibXML->new;


    #my $doctotest    = $parser->parse_string($doc);

    # $logger->log( "Testing against LibraryShipNotice v1.0 schema... ");

    # my $schemafile = "schema.xsd";

    # my $xmlschema = XML::LibXML::Schema->new(location => $schemafile, no_network => 1);
    # eval { $xmlschema->validate($doctotest); };
    # die $@ if $@;
    # $logger->logError( "XML schema validation success. ");

  my $vendoridentifier;
  my $buyeridentifier;

  $logger->log("\nValidating file: " . $filename);
  $logger->logError("\n-- Validating file " . $fileforlog);
  

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/ProductID/Identifier')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "Identifier not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/ItemDescription/ProductForm')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "ProductForm not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/ItemDescription/Title')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "Title not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/ItemDescription/YearOfPublication')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "YearOfPublication not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/QuantityShipping')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "QuantityShipping not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/PricingDetail/Price/MonetaryAmount')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "MonetaryAmount not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/PricingDetail/Price/PriceQualifierCode')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "PriceQualifierCode not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/PricingDetail/Price/Tax/TaxTypeCode')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "TaxTypeCode not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/PricingDetail/Price/Tax/Percent')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "Tax Percent not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/SubLineNumber')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "SubLineNumber not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/CopyQuantity')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "CopyQuantity not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/DeliverToLocation')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "DeliverToLocation not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/DestinationLocation')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "DestinationLocation not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/ProcessingInstructionCode')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "ProcessingInstructionCode not present");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/CopyValue/MonetaryAmount')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "CopyValue MonetaryAmount not present ");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/FundDetail/MonetaryAmount')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "FundDetail MonetaryAmount not present ");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/Message/MessageType')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "MessageType not present ");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/Summary/NumberOfLines')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "NumberOfLines not present ");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/Summary/UnitsShipped')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "UnitsShipped not present ");
      $errors++;
    }

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/Message/MessageLine')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "MessageLine not present ");
      $errors++;
    }

    #Do tests to marcxml
    try {
      my $marcxml = MARC::Record::new_from_xml($val, 'UTF-8');

      my $test = $marcxml->subfield('245', 'a');

      if ($test eq "") {
        $logger->logError($fileforlog . "Marcxml test value (245a) null ");
        $errors++;
      }
    } catch {
      $errors++;
      $logger->logError($fileforlog . "MessageLine marcxml " . "$_");
    };

    #$logger->log( "245a: " . $test . "");

  }
  
  foreach my $title ($xc->findnodes('LibraryShipNotice/Header/BuyerParty/PartyName/NameLine')) {
    my $val = $title->to_literal();

    if ($val eq "") {
      $logger->logError($fileforlog . "BuyerParty PartyID Nameline not present");
      die;
    }
    $logger->log("BuyerParty PartyID Nameline: " . $val);


  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/Header/SellerParty/PartyName/NameLine')) {
    my $val = $title->to_literal();
    $val = "$val";

    if ($val eq "") {
      $logger->log($fileforlog . "SellerParty PartyID Nameline not present");
      $errors++;
    } else {
      $logger->log("SellerParty PartyID Nameline: " . $val);
      my $valid = $val eq 'Kirjavälitys Oy' || $val eq 'Booky.fi Oy' || $val eq 'BTJ Finland Oy';
      if (not $valid) {
        $logger->logError($fileforlog . "SellerParty PartyID Nameline is unknown.");
        $errors++;
      }
    }
  }


  foreach my $title ($xc->findnodes('LibraryShipNotice/Header/BuyerParty/PartyID/Identifier')) {
    my $val = $title->to_literal();

    if ($val eq "") {
      $logger->logError("PartyID Vendor Identifier not present");
    }

    $vendoridentifier = $val;
    $logger->log("PartyID Vendor Identifier: " . $vendoridentifier);

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/Header/SellerParty/PartyID/Identifier')) {
    my $val = $title->to_literal();

    if ($val eq "") {
      $logger->logError($fileforlog . "PartyID Buyer Identifier not present");
    }

    $buyeridentifier = $val;
    $logger->log("PartyID Buyer Identifier: " . $buyeridentifier);

  }

  foreach my $title ($xc->findnodes('LibraryShipNotice/Header/BuyerParty/PartyID/PartyIDType')) {
    my $val = $title->to_literal();

    if ($val eq "") {
      $logger->logError($fileforlog . "PartyIDType not present");

      $errors++;
    }
    $logger->log("PartyIDType: " . $val);

    my ($san, $qualifier, $bookseller) = (0, 91, 0);

    $san = $vendoridentifier;
    if (!$san) {
      $san       = $buyeridentifier;
      $qualifier = 92;
    }

    my $dbh   = C4::Context->dbh;
    my $stmnt = $dbh->prepare("SELECT vendor_id FROM vendor_edi_accounts WHERE san = ? AND id_code_qualifier=? AND transport='FILE' AND orders_enabled='1'");
    $stmnt->execute($san, $qualifier) or die($DBI::errstr);
    $bookseller = $stmnt->fetchrow_array();

    if (!$bookseller) {
      if ($san) {
        $logger->logError($fileforlog . "No vendor for SAN $san (qualifier $qualifier) in vendor_edi_accounts.");
        $errors++;
      } else {
        $logger->logError($fileforlog . "No vendor in shipment notice.");
        $errors++;
      }
    }

  }

  #Check FundNumber exists in Koha
  foreach my $title ($xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/FundDetail/FundNumber')) {
    my $val = $title->to_literal();
    if ($val eq "") {
      $logger->logError($fileforlog . "FundNumber not present");
      $errors++;

    } else {

      #$logger->log( "FundNumber: ". $val);
      my $dbh   = C4::Context->dbh;
      my $stmnt = $dbh->prepare("SELECT budget_code FROM aqbudgets WHERE budget_code = ? ");
      $stmnt->execute($val) or die($DBI::errstr);
      my $budget_id = $stmnt->fetchrow_array();

      if (!$budget_id) {
        $logger->logError($fileforlog . "No matching FundNumber found: " . $val);
        $errors++;
      }
    }
  }

  $logger->logError($fileforlog . "LibraryShipNotice errors: " . $errors);
  if ($errors > 0) {
    $logger->logError($fileforlog . "Validation failed");
    $logger->log("LibraryShipNotice errors detected -> must die.");
    die;
  } else {
    $logger->log("Validation success.");
  }
}

1;


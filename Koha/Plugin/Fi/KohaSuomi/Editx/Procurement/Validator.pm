#!/usr/bin/perl

package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator;

use strict;
use Modern::Perl;
use XML::LibXML qw ();
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

  $logger->log("\n\nValidating file: " . $filename);

  try {

    $parser = XML::LibXML->new();
    $doc    = XML::LibXML->load_xml(location => $filename);
    $xc     = XML::LibXML::XPathContext->new($doc);

    my $node;

    $node = $xc->find('LibraryShipNotice');


    if ($node eq "" or $node->to_literal eq "") {

      $logger->logError($fileforlog . "Not a LibraryShipNotice XML file");
      die;
    }

  } catch {

    $logger->logError($fileforlog . "XML parser cannot parse the file. " . "$_");
    die;
  };

#validate against koha schema
# $xc->registerNs('acs', "http://openncip.org/acs-config/1.0/");

# my $doctotest    = $parser->parse_string($doc);

# $logger->log( "Testing against Koha-Suomi LibraryShipNotice v1.0 schema... ");

# my $schemafile = "LibraryShipNotice_schema_KS.xsd";

# my $xmlschema = XML::LibXML::Schema->new(location => $schemafile, no_network => 1);

# my $res = eval { $xmlschema->validate( $doctotest ); };
# die $logger->logError($fileforlog . "XML schema validation failed.". $@) if $@;

# $logger->log( "XML schema validation success. ");

  my $vendoridentifier;
  my $buyeridentifier;

#Check Pre-Itemdetail Nodes required Header nodes
  my $node;
  my @nodes;

  $node = $xc->find('LibraryShipNotice/Header/BuyerParty/PartyName/NameLine');

  if ($node eq "" or $node->to_literal eq "") {

    $logger->logError($fileforlog . "LibraryShipNotice/Header/BuyerParty/PartyName/NameLine not present");
    $errors++;
  }

# LibraryShipNotice/Header/SellerParty/PartyName/NameLine

  $node = $xc->find('LibraryShipNotice/Header/SellerParty/PartyName/NameLine');

  if ($node eq "" or $node->to_literal eq "") {
    $logger->logError($fileforlog . "LibraryShipNotice/Header/SellerParty/PartyName/NameLine not present");
    $errors++;

  } else {

    my $val   = $node->to_literal();
    my $valid = $val eq 'Kirjavälitys Oy' || $val eq 'Booky.fi Oy' || $val eq 'BTJ Finland Oy';

    if (not $valid) {
      $logger->logError($fileforlog . "SellerParty PartyName Nameline '" . $val . "' is unknown.");
      $errors++;
    }
  }

# LibraryShipNotice/Header/BuyerParty/PartyID/Identifier

  $node = $xc->find('LibraryShipNotice/Header/BuyerParty/PartyID/Identifier');

  if ($node eq "" or $node->to_literal eq "") {

    $logger->logError($fileforlog . "LibraryShipNotice/Header/BuyerParty/PartyID/Identifier not present");
    $errors++;

  } else {

    my $val = $node->to_literal();
    $buyeridentifier = $val;

  }

# LibraryShipNotice/Header/SellerParty/PartyID/Identifier

  $node = $xc->find('LibraryShipNotice/Header/SellerParty/PartyID/Identifier');

  if ($node eq "" or $node->to_literal eq "") {

    $logger->logError($fileforlog . "LibraryShipNotice/Header/SellerParty/PartyID/Identifier not present");
    $errors++;

  } else {

    my $val = $node->to_literal();
    $vendoridentifier = $val;

  }

# LibraryShipNotice/Header/BuyerParty/PartyID/PartyIDType

  $node = $xc->find('LibraryShipNotice/Header/BuyerParty/PartyID/PartyIDType');

  if ($node eq "" or $node->to_literal eq "") {

    $logger->logError($fileforlog . "LibraryShipNotice/Header/BuyerParty/PartyID/PartyIDType not present");
    $errors++;

  } else {

    my $val = $node->to_literal();

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

# LibraryShipNotice/Summary/NumberOfLines

  @nodes = $xc->findnodes('LibraryShipNotice/Summary/NumberOfLines');
  if (!@nodes) {
    $logger->logError($fileforlog . "NumberOfLines not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "NumberOfLines not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/Summary/UnitsShipped

  @nodes = $xc->findnodes('LibraryShipNotice/Summary/UnitsShipped');
  if (!@nodes) {
    $logger->logError($fileforlog . "UnitsShipped not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "UnitsShipped not present ");
        $errors++;
      }
    }
  }

# Itemdetail checks

# LibraryShipNotice/ItemDetail/CopyDetail/FundDetail/FundNumber

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/FundDetail/FundNumber');
  if (!@nodes) {
    $logger->logError($fileforlog . "FundNumber not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "FundNumber not present ");
        $errors++;
      } else {

        #Check FundNumber exists in Koha
        my $val   = $node->to_literal;
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
  }

# LibraryShipNotice/ItemDetail and ProductIDs (EAN/ISBN)

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail');
  my $nodecount = @nodes;

  if (!@nodes) {
    $logger->logError($fileforlog . "ItemDetails not present ");
    $errors++;

  } else {
    @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/ProductID');

    my $ean_ok  = 0;
    my $isbn_ok = 0;
    foreach my $node (@nodes) {

      my $idtypenode = $node->getChildrenByTagName('ProductIDType');

      if ($idtypenode eq "" or $idtypenode->to_literal eq "") {
        $logger->logError($fileforlog . "ProductIDType not present ");
        $errors++;
      } else {

        if ($idtypenode->to_literal eq "EAN13") {

          my $ean = $node->getChildrenByTagName('Identifier');
          if ($ean eq "" or $ean->to_literal eq "") {
            $logger->logError($fileforlog . "EAN not present ");
            $errors++;
          } else {
            $ean_ok++;
          }

        }
        if ($idtypenode->to_literal eq "ISBN") {

          my $isbn = $node->getChildrenByTagName('Identifier');
          if ($isbn eq "" or $isbn->to_literal eq "") {
            $logger->logError($fileforlog . "ISBN not present ");
            $errors++;
          } else {
            $isbn_ok++;
          }
        }
      }
    }

    if ($ean_ok == $nodecount && $isbn_ok == $nodecount) {

    } else {
      $logger->logError($fileforlog . "EANs or ISBNs missing from ItemDetail, must include both");
      $errors++;
    }
  }

# LibraryShipNotice/ItemDetail/ItemDescription/ProductForm

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/ItemDescription/ProductForm');
  if (!@nodes) {
    $logger->logError($fileforlog . "ProductForm not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "ProductForm not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/ItemDescription/Title

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/ItemDescription/Title');
  if (!@nodes) {
    $logger->logError($fileforlog . "Title not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "Title not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/ItemDescription/PublisherName

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/ItemDescription/PublisherName');
  if (!@nodes) {
    $logger->logError($fileforlog . "PublisherName not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "PublisherName not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/ItemDescription/YearOfPublication

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/ItemDescription/YearOfPublication');
  if (!@nodes) {
    $logger->logError($fileforlog . "YearOfPublication not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "YearOfPublication not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/QuantityShipping

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/QuantityShipping');
  if (!@nodes) {
    $logger->logError($fileforlog . "QuantityShipping not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "QuantityShipping not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/PricingDetail/Price/MonetaryAmount

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/PricingDetail/Price/MonetaryAmount');
  if (!@nodes) {
    $logger->logError($fileforlog . "MonetaryAmount not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "MonetaryAmount not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/PricingDetail/Price/PriceQualifierCode

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/PricingDetail/Price/PriceQualifierCode');
  if (!@nodes) {
    $logger->logError($fileforlog . "PriceQualifierCode not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "PriceQualifierCode not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/PricingDetail/Price/Tax/TaxTypeCode

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/PricingDetail/Price/Tax/TaxTypeCode');
  if (!@nodes) {
    $logger->logError($fileforlog . "TaxTypeCode not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "TaxTypeCode not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/PricingDetail/Price/Tax/Percent

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/PricingDetail/Price/Tax/Percent');
  if (!@nodes) {
    $logger->logError($fileforlog . "Tax Percent not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "Tax Percent not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/CopyDetail/SubLineNumber

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/SubLineNumber');
  if (!@nodes) {
    $logger->logError($fileforlog . "SubLineNumber not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "SubLineNumber not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/CopyDetail/CopyQuantity

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/CopyQuantity');
  if (!@nodes) {
    $logger->logError($fileforlog . "CopyQuantity not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "CopyQuantity not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/CopyDetail/DeliverToLocation

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/DeliverToLocation');
  if (!@nodes) {
    $logger->logError($fileforlog . "DeliverToLocation not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "DeliverToLocation not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/CopyDetail/DestinationLocation

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/DestinationLocation');
  if (!@nodes) {
    $logger->logError($fileforlog . "DestinationLocation not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "DestinationLocation not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/CopyDetail/ProcessingInstructionCode

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/ProcessingInstructionCode');
  if (!@nodes) {
    $logger->logError($fileforlog . "ProcessingInstructionCode not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "ProcessingInstructionCode not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/CopyDetail/CopyValue/MonetaryAmount

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/CopyValue/MonetaryAmount');
  if (!@nodes) {
    $logger->logError($fileforlog . "CopyValue MonetaryAmount not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "CopyValue MonetaryAmount not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/CopyDetail/FundDetail/MonetaryAmount

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/FundDetail/MonetaryAmount');
  if (!@nodes) {
    $logger->logError($fileforlog . "FundDetail MonetaryAmount not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "FundDetail MonetaryAmount not present ");
        $errors++;
      }
    }
  }

# LibraryShipNotice/ItemDetail/CopyDetail/Message/MessageType

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/Message/MessageType');
  if (!@nodes) {
    $logger->logError($fileforlog . "MessageType not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "MessageType not present ");
        $errors++;
      }
    }
  }

  @nodes = $xc->findnodes('LibraryShipNotice/ItemDetail/CopyDetail/Message/MessageType');
  if (!@nodes) {
    $logger->logError($fileforlog . "MessageType not present ");
    $errors++;
  } else {
    foreach my $node (@nodes) {

      if ($node eq "" or $node->to_literal eq "") {
        $logger->logError($fileforlog . "MessageType not present ");
        $errors++;
      } else {
        my $val = $node->string_value();

        if ($val eq "") {
          $logger->logError($fileforlog . "MessageType not present");
          $errors++;
        } elsif ($val ne "04" && $val ne "01") {
          $logger->logError($fileforlog . "Wrong type of MessageType found: " . $val);
          $errors++;
        } elsif ($val eq "01") {
          $logger->log("MessageType 01 found, passing xml test");
        } elsif ($val eq "04") {
          $logger->log("MessageType 04 present, testing xml");

          #Do tests to marcxml
          my $messageLine = $node->parentNode->find('MessageLine');
          my $xml         = $messageLine->string_value();

          #my $xml = $messageLine->nodeValue;

          if ($xml eq "") {
            $logger->logError($fileforlog . "MessageLine not present");
            $errors++;

          } else {

            try {
              my $marcxml = MARC::Record::new_from_xml($xml, 'UTF-8');

              my $test = $marcxml->subfield('245', 'a');
              $logger->log("MessageLine marcxml 245a: " . $test);

            } catch {

              $errors++;
              $logger->logError($fileforlog . "MessageLine marcxml " . "$_");
            }
          }
        }
      }
    }
  }

# Error handling

  $logger->logError($fileforlog . "LibraryShipNotice required values errors: " . $errors);
  if ($errors > 0) {
    $logger->logError($fileforlog . "Validation failed");
    $logger->log("LibraryShipNotice errors detected -> must die.");
    die;

  } else {
    $logger->log("Validation success.");
  }
}

1;

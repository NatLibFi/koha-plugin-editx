#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor::Order;

use Moose;
use C4::Context;
use C4::Acquisition;
use Data::Dumper;

sub createOrder {
    my $self = shift;
    my ($copyDetail, $itemDetail, $shipment_order, $biblio, $basketNumber, $authoriser) = @_;
    my $price = $itemDetail->getPriceFixedRPExcludingTax();
    my $tax_price = $itemDetail->getPriceFixedRPExcludingTax();
    my $fundNumber = $copyDetail->getFundNumber();
    my $budgetId = $self->getBudgetId($fundNumber);
    die "No Koha budget found for EDItX FundNumber '$fundNumber'." unless $budgetId;
    
        my $order = Koha::Acquisition::Order->new(
            {
                basketno           => $basketNumber,
                biblionumber       => $biblio,
                title              => $itemDetail->getTitle(),
                quantity           => $copyDetail->getCopyQuantity(),
                order_vendornote   => $shipment_order->getFileName(),
                order_internalnote => $itemDetail->getReferenceNumber(),  
                created_by         => $authoriser,    
                rrp                => $price,
                rrp_tax_excluded   => $price,
                rrp_tax_included   => $price,
                ecost              => $price,
                ecost_tax_excluded => $price,
                ecost_tax_included => $price,
                replacementprice   => $price,
                unitprice          => $price,
                unitprice_tax_excluded => $price,
                unitprice_tax_included => $price,
                listprice          => $price,
                budget_id          => $budgetId,
                currency           => $itemDetail->getPriceSRPECurrency(),
                orderstatus => 'new'
            }
        )->store;

    die "Could not create Koha acquisition order for FundNumber '$fundNumber'." unless $order && $order->ordernumber;

    return $order->ordernumber;
}

sub createOrderItem
{
   my $self = shift;
   my $itemnumber = shift;
   my $ordernumber = shift;

   my $order = Koha::Acquisition::Orders->find({ ordernumber => $ordernumber });
   die "Could not link item $itemnumber to order $ordernumber: order not found." unless $order;
   $order->add_item( $itemnumber );

   return 1;
}

sub getBudgetId {
   my $self = shift;
   my $fundNumber = $_[0];
   my $dbh = C4::Context->dbh;

   my $stmnt = $dbh->prepare("SELECT max(budget_id) FROM aqbudgets WHERE budget_code = ?");
   $stmnt->execute($fundNumber);
   my $budgetId = $stmnt->fetchrow_array();
   $stmnt->finish();

   return $budgetId;
}


1;

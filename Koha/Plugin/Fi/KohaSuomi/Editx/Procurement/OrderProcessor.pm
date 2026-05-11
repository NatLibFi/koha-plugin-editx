#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor;

use Moose;
use C4::Context;
use Data::Dumper;
use POSIX qw(strftime);

use Koha::Database;
use Koha::Item;
use Koha::Biblio;
use Koha::Biblioitem;
use Koha::Biblio::Metadata;
use C4::Biblio;
use Koha::DateUtils;
use C4::Barcodes::ValueBuilder;
use utf8;
use List::MoreUtils qw(uniq);
use Data::Dumper;
use YAML::XS;

use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor::Order;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor::Basket;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::MarcHelper;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::VendorEdiAccount;

use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::FinnaMaterialType;
use C4::Languages qw(getlanguage);

use constant KOHA_SUOMI_SPEND_LOG_TABLE => 'aqbudgets_spend_log';

my $editx_plugin_class = 'Koha::Plugin::Fi::KohaSuomi::Editx';
my $sequences_table = _quote_identifier( _plugin_table_name('sequences') );
my $map_productform_table = _quote_identifier( _plugin_table_name('map_productform') );

has 'schema' => (
    is      => 'rw',
    isa => 'DBIx::Class::Schema',
    reader => 'getSchema',
    writer => 'setSchema'
);

has 'logger' => (
    is      => 'rw',
    isa => 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger',
    reader => 'getLogger',
    writer => 'setLogger'
);

has 'config' => (
    is      => 'rw',
    isa => 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config',
    reader => 'getConfig',
    writer => 'setConfig'
);

sub BUILD {
    my $self = shift;
    my $schema = Koha::Database->new()->schema();
    $self->setSchema($schema);
    $self->setLogger(new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger);
    $self->setConfig(new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config);
}

sub _plugin_table_name {
    my ($table_name) = @_;

    return lc( join( '_', split( '::', $editx_plugin_class ), $table_name ) );
}

sub _quote_identifier {
    my ($identifier) = @_;

    $identifier =~ s/`/``/g;
    return "`$identifier`";
}

sub _sequences_table {
    return $sequences_table;
}

sub _map_productform_table {
    return $map_productform_table;
}

# We are old and obsolete
# sub startProcessing {
#     my $self = shift;
#     my $dbh = C4::Context->dbh;
#     my $schema = $self->getSchema();
#     $dbh->do('START TRANSACTION');
# }

# sub endProcessing {
#     my $self = shift;
#     my $dbh = C4::Context->dbh;
#     $dbh->do('COMMIT');
# }

# sub rollBack {
#     my $self = shift;
#     my $dbh = C4::Context->dbh;
#     $dbh->do('ROLLBACK');
# }

sub process {   
    my $self = shift;
    my $order = $_[0];
    my $orderCreator = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor::Order->new;
    my $basketHelper = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor::Basket->new;
    if(!$order){
        $self->getLogger()->logError("Order not set.");
        return 0;
    }
    my $itemDetails = $order->getItems();
    if(scalar @$itemDetails <= 0){
        $self->getLogger()->logError('Order has no items.');
        return 0;
    }

    my ($item, $copyDetail, $copyQty, $barCode, $biblio, $biblioitem, $basketNumber, $bookseller, $itemId, $orderId);
    my $authoriser = $self->getAuthoriser();
    my $basketName = $order->getBasketName();
  
    $self->getLogger()->debug("getAuthoriser: " . $authoriser);
    $self->getLogger()->debug("getBasketName: " . $basketName);
    
    my (@copydetailstoadd, @itemstoadd, @orderstoadd, @bibliostoadd);

    foreach(@$itemDetails){
        $item = $_;
        my $copyDetails = $item->getCopyDetail();
        foreach(@$copyDetails){
            $copyDetail = $_;
            ($biblio, $biblioitem) = $self->getBiblioDatas($copyDetail, $item, $order);
            $self->getLogger()->debug("getBiblioDatas biblio: ". $biblio);
            $copyQty = $copyDetail->getCopyQuantity();
            if($copyQty > 0){
                $bookseller = $self->getBookseller($order);
                $basketNumber = $basketHelper->getBasket($bookseller, $authoriser, $basketName );
                
                $orderId = $orderCreator->createOrder($copyDetail, $item, $order, $biblio, $basketNumber, $authoriser);
                $self->getLogger()->log("createOrder orderId: " . $orderId);
                for(my $i = 0; $copyQty > $i; $i++ ){
                    $itemId = $self->createItem($copyDetail, $item, $order, $barCode, $biblio, $biblioitem);

                    $orderCreator->createOrderItem($itemId, $orderId);
                    
                }
                

                # $self->updateAqbudgetLog($copyDetail, $item, $order, $biblio);
                        
                # $self->getLogger()->log("Adding bibliographic record $biblio to Zebra queue.");
                        
                # C4::Biblio::ModZebra( $biblio, "specialUpdate", "biblioserver" );

                push @copydetailstoadd, $copyDetail;
                
                push @itemstoadd, $item;
                
                push @orderstoadd, $order;
                
                push @bibliostoadd, $biblio;
                
            }
        }
    }
    
    my $arr_size = @copydetailstoadd;
    if ( !$arr_size ) {
        $self->getLogger()->logError('Order produced no orderable copy details.');
        return 0;
    }
    
    $self->getLogger()->log("Updating aqbudgets ($arr_size items)...");
        
    for(my $i = 0; $i <= $arr_size -1; $i++){
         
        $self->updateAqbudgetLog($copydetailstoadd[$i], $itemstoadd[$i], $orderstoadd[$i], $bibliostoadd[$i]);
    }
    
    $self->getLogger()->log("Budgets updated.");
    
    #   by the words of Johanna's granny concerning her 2-bristled dishwasher brush: 'You never know when you might need to use it'
    #for(my $i = 0; $i <= $arr_size -1; $i++){
    #    
    #    C4::Biblio::ModZebra( $bibliostoadd[$i], "specialUpdate", "biblioserver" );
    #    $self->getLogger()->log("Added bibliographic record $bibliostoadd[$i] to Zebra queue.");
    #}

    if ( !$basketHelper->closeBasket($basketName) ) {
        $self->getLogger()->warn("Basket '$basketName' was not closed because it was not opened during this import.");
    }

    return 1;
}

sub getBiblioDatas {   
    my $self = shift;
    my ($copyDetail, $itemDetail, $order) = @_;
    my ($biblio, $biblioitem, $bibliometa);
    
    my $copydetails = Data::Dumper::Dumper $copyDetail; 
    my $itemdetails = Data::Dumper::Dumper $itemDetail; 
    my $orderdetails = Data::Dumper::Dumper $order; 

    if($self->getConfig()->getUseAutomatchBiblios() ne 'no'){
        ($biblio, $biblioitem) = $self->getBiblioItemData($copyDetail, $itemDetail, $order);
    }
    if( !$biblio && !$biblioitem ){
        my $prodform;
        $biblio = $self->createBiblio($copyDetail, $itemDetail, $order);
        my $bibdetails = Data::Dumper::Dumper $biblio;
        
        if ($self->getConfig()->getUseFinnaMaterials() eq 'yes') {
            $prodform = getFinnaMaterialType($copyDetail->getMarcData(), 'fi_FI');
        } else {
            $prodform = $self->getProductForm($itemDetail->getProductForm());
        }
        $copyDetail->addMarc942($prodform);
        $copyDetail->fixMarcIsbn();
        $copyDetail->fixMarc005();
        ($biblioitem) = $self->createBiblioItem($copyDetail, $itemDetail, $order, $biblio);
        my $bibitemdetails = Data::Dumper::Dumper $biblioitem; 
        $self->getLogger()->debug("createBiblioItem biblioitem: " . $bibitemdetails);
        
        $bibliometa = $self->createBiblioMetadata($copyDetail, $itemDetail, $order, $biblio);
        
        my $bibmeta = Data::Dumper::Dumper $bibliometa;
        $self->getLogger()->debug("createBiblioMetadata bibliometa: " . $bibmeta);

        my $biblio_object = Koha::Biblios->find($biblio);
        if(! $biblio_object){
           die "Getting Biblio $biblio failed.";
        }
        my $marcBiblio;
        eval { $marcBiblio = $biblio_object->metadata->record({ embed_items => 1 }); };
        if ($@) {
            die "Getting metadata record for Biblio $biblio died: $@";
        }
        if (! $marcBiblio) {
            die "Getting metadata record for Biblio $biblio returned empty result.";
        }
        if(! C4::Biblio::ModBiblio($marcBiblio, $biblio, '')){
           die('C4::Biblio::Modbiblio failed.');
        }
    }
    
    return ($biblio, $biblioitem);
}

sub getBiblioItemData {  
    my $self = shift;
    my ($copyDetail, $itemDetail, $order) = @_;
    my (@isbns, $stdind, $ean, $publishercode, $editionresponsibility, $rows, $row, @result);
    my $isbns1 = $itemDetail->getIsbns();
    push @isbns, @$isbns1;
    my $isbns2 = $copyDetail->getIsbns();
    push @isbns, @$isbns2;
    @isbns = uniq @isbns;
    
    $stdind = $copyDetail->getStandardIdentifierIndicator();
    $ean = $copyDetail->getMarcStdIdentifier();
    $publishercode = $copyDetail->getMarcPublisherIdentifier();
    $editionresponsibility = $copyDetail->getMarcPublisher();

    if(@isbns){
        $rows = $self->getItemsByIsbns(@isbns);
    }

    if($ean && (!$rows || $rows->count <= 0)){
        $rows = $self->getItemsByEan($stdind,$ean);
    }
    if($publishercode && $editionresponsibility && (!$rows || $rows->count <= 0)){
        $rows = $self->getItemByColumns({ publishercode => $publishercode, editionresponsibility => $editionresponsibility });
    }

    if($rows && $rows->count > 0 ){
         $row = $rows->next;
         if($row && defined $row->biblionumber->biblionumber && defined $row->biblioitemnumber ){
            @result = ($row->biblionumber->biblionumber, $row->biblioitemnumber, $row->isbn);
         }
    }

    return @result;
}

sub getFundYear {  
    my $self = shift;
    my $budgetCode = $_[0];
    my $budgetperiodid = $_[1];
    my $year;
    my $dbh = C4::Context->dbh;
    my $stmnt = $dbh->prepare("select distinct year(a.budget_period_enddate) from aqbudgetperiods a, aqbudgets b
                             where a.budget_period_active = 1
                             and a.budget_period_id = ?
                             and a.budget_period_id = b.budget_period_id
                             and b.budget_code like ? " );
    my $budgetCodeLike = $budgetCode . "%";

    $stmnt->execute($budgetperiodid, $budgetCodeLike);
    if ($stmnt->rows >= 1){
        $year = $stmnt->fetchrow_array();
    }
    else{
        $year = strftime "%Y", localtime;
    }
     return $year;
}

sub generateBarcode {   
    my ($self, $args, $autoBarcodeType) = @_;

    my $prefix = $args->{prefix} || undef;
    my $date = $args->{date};
    $self->advanceBarcodeValue($date, $args->{prefixes});

    my $barcode;
    my $nextnum = $self->getBarcodeValue();

    if( (($autoBarcodeType // '') eq 'preyymmddts' && $prefix) ){
        $barcode = $prefix.$date.$nextnum;
    } else {
        $barcode = "HANK_".$date.$nextnum;
    }

    return $barcode;
}

sub barcodePrefixesFromPreference {
    my ( $self, $branchPrefixes ) = @_;

    return {} unless defined $branchPrefixes && $branchPrefixes =~ /\S/;

    my $yaml = eval {
        YAML::XS::Load(
            Encode::encode(
                'UTF-8',
                $branchPrefixes,
                Encode::FB_CROAK
            )
        );
    };
    if ( my $error = $@ ) {
        chomp $error;
        die "BarcodePrefix system preference is invalid YAML. Expected a mapping like \"Default: HANK_\" or \"MAIN: MAIN_\". Error: $error";
    }
    if ( !ref $yaml ) {
        return { Default => $yaml } if defined $yaml && $yaml ne '';
        return {};
    }
    if ( ref $yaml ne 'HASH' ) {
        die 'BarcodePrefix system preference must be a YAML mapping like "Default: HANK_" or "MAIN: MAIN_", or a single global prefix value.';
    }

    return $yaml;
}

sub getMarcFromKohaFieldCompat {
    my ( $self, $kohafield ) = @_;

    my @mapping = eval { C4::Biblio::GetMarcFromKohaField($kohafield) };
    return @mapping if !$@ && defined $mapping[0] && defined $mapping[1];

    return C4::Biblio::GetMarcFromKohaField( $kohafield, '' );
}

sub advanceBarcodeValue {  
    my ($self, $date, $prefixes) = @_;
    my $dbh = C4::Context->dbh;
    my $sequences_table = $self->_sequences_table();

    my $regex = sprintf "%s$date|" x @$prefixes, @$prefixes;
    $regex .= "HANK_$date";

    my $update_query = "UPDATE $sequences_table SET item_barcode_nextval = item_barcode_nextval+1";
    my $query = 'SELECT MAX(CAST(SUBSTRING(barcode,-5) AS signed)) FROM items WHERE barcode REGEXP "'.$regex.'"';
    my $stmnt = $dbh->prepare($query);
    $stmnt->execute();

    while (my ($count)= $stmnt->fetchrow_array) {
        if(!$count || $count == 9999){
            $update_query = "UPDATE $sequences_table SET item_barcode_nextval = 1";
        }
    }

    $stmnt = $dbh->prepare($update_query);
    $stmnt->execute();
}

sub getBarcodeValue {  
    my $self = shift;

    my $dbh = C4::Context->dbh;
    my $sequences_table = $self->_sequences_table();
    my $stmnt = $dbh->prepare("SELECT max(item_barcode_nextval) FROM $sequences_table");
    $stmnt->execute();

    my $nextnum = sprintf("%0*d", "5",$stmnt->fetchrow_array());

    return $nextnum;
}

sub getItemsByIsbns {   
    my $self = shift;
    my @isbnArray = @_;
    my $resultSet = $self->getSchema()->resultset(Koha::Biblioitem->_type());
    my $result = -1;

    if(@isbnArray > 0){
        $result = $resultSet->search({'isbn' => {'in' => \@isbnArray}},{ select => [qw/isbn biblionumber biblioitemnumber/] });
    }
    return $result;
}

sub getItemsByEan {   
    my $self = shift;
    my $stdindicator = $_[0];
    my $stdid = $_[1]; # standard identifier type, e.g. EAN defined by indicator
    my $resultSet = $self->getSchema()->resultset(Koha::Biblioitem->_type());
    my $result = -1;

    if($stdindicator && $stdid && $stdindicator != '8'){
        $result = $resultSet->search({'ean' => {'like' => "%$stdid%"}},{ select => [qw/isbn biblionumber biblioitemnumber/] }); #multipe EAN matching
    }
    elsif($stdindicator && $stdid && $stdindicator == '8'){
        $result = $resultSet->search({'ean' => $stdid},{ select => [qw/isbn biblionumber biblioitemnumber/] }); #Exact match for Puppe shortcodes #KOHA-1996
    }
    return $result;
}

sub getItemByColumns {   
    my $self = shift;
    my $columns = $_[0];

    my $resultSet = $self->getSchema()->resultset(Koha::Biblioitem->_type());
    my $result = -1;

    if($columns){
        $result = $resultSet->search($columns, { select => [qw/isbn biblionumber biblioitemnumber/] });
    }

    return $result;
}


sub createBiblio {    
    my $self = shift;
    my ($copyDetail, $itemDetail, $order) = @_;
    my $result = 0;
    my $data = {};

    if($itemDetail->isa('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail') ){
        $data->{'author'} = $itemDetail->getAuthor();
        $data->{'title'} = $itemDetail->getTitle();
        $data->{'notes'} = $itemDetail->getNotes();
        $data->{'seriestitle'} = $itemDetail->getSeriesTitle();;
        $data->{'copyrightdate'} = $copyDetail->getYearOfPublication();
        $data->{'timestamp'} = $order->getTimeStamp();
        $data->{'datecreated'} = $order->getDateCreated();

        my @paramsToValidate = ('title', 'notes', 'timestamp', 'datecreated');
        if($self->validate({'params', \@paramsToValidate , 'data', $data })){

            my $biblio = Koha::Biblio->new(
                {
                    author        => $data->{author},
                    title         => $data->{title},
                    notes         => $data->{notes},
                    timestamp     => $data->{timestamp},
                    datecreated   => $data->{datecreated}
                }
            );
            
            $biblio->{copyrightdate} = $data->{copyrightdate} if(defined $data->{copyrightdate} && $data->{copyrightdate} ne '');
            $biblio->{seriestitle} = $data->{seriestitle} if(defined $data->{seriestitle} && $data->{seriestitle} ne '');
            
            $biblio->store or die($DBI::errstr);
            
            
            
            Koha::Exceptions::ObjectNotCreated->throw unless $biblio;
            
            $result = $biblio->biblionumber;
            Koha::Exceptions::ObjectNotCreated->throw unless $result;
            $self->getLogger()->debug("createBiblio stored biblionumber: ". $result);
        }
        else{
            die('createBiblio: Required params not set.');
        }
    }
    return $result;
}

sub createBiblioItem {   
    my $self = shift;
    my ($copyDetail, $itemDetail, $order, $biblio) = @_;
    my (@result, $id);
    my $data = {};
    
    if($itemDetail->isa('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail') ){
        $data->{'biblio'} = $biblio;
        $data->{'productform'} = $self->getProductForm($itemDetail->getProductForm());

        $data->{'isbn'} = $copyDetail->getIsbn();
        $data->{'ean'} = $copyDetail->getMarcStdIdentifier();
        $data->{'publishercode'} = $copyDetail->getMarcPublisherIdentifier();
        $data->{'editionresponsibility'} = $copyDetail->getMarcPublisher();

        $data->{'productidtype'} = $itemDetail->getProductIdType();
        $data->{'publishername'} = $copyDetail->getPublisherName();
        $data->{'yearofpublication'} = $copyDetail->getYearOfPublication();
        $data->{'editionstatement'} = $copyDetail->getEditionStatement();
        $data->{'timestamp'} = $order->getTimeStamp();
        my $marc = $copyDetail->getMarcXml();
        utf8::decode($marc);
        $data->{'marcxml'} = $marc;
        $data->{'notes'} = $itemDetail->getNotes();
        $data->{'image'} = $copyDetail->getImageDescrition();
        $data->{'pages'} = $copyDetail->getPages();
        $data->{'place'} = $copyDetail->getPlace();
        $data->{'url'} = '';

        my @paramsToValidate = ('biblio', 'productform', 'timestamp', 'marcxml', 'notes');
        my @isbn = ('isbn');
        my @ean = ('ean');
        my @identifierParams = ('publishercode', 'editionresponsibility');
        if($self->validate({'params', \@paramsToValidate , 'data', $data })
            #&& ($self->validate({'params', \@isbn , 'data', $data }) || $self->validate({'params', \@ean , 'data', $data }) || $self->validate({'params', \@identifierParams , 'data', $data }) )
        ){          
            my $biblioItem = Koha::Biblioitem->new(
                {
                    biblionumber        => $data->{biblio},
                    itemtype         => $data->{productform},
                    timestamp         => $data->{timestamp},
                    notes     => $data->{notes},
                    publishercode => $data->{publishername}
                }
            );
            
            $biblioItem->{isbn} = $data->{isbn} if(defined $data->{isbn} && $data->{isbn} ne '');
            $biblioItem->{ean} = $data->{ean} if(defined $data->{ean} && $data->{ean} ne '');
            $biblioItem->{publicationyear} = $data->{yearofpublication} if(defined $data->{yearofpublication} && $data->{yearofpublication} ne '');
            $biblioItem->{publishercode} = $data->{publishercode} if(defined $data->{publishercode} && $data->{publishercode} ne '');
            $biblioItem->{editionresponsibility} = $data->{editionresponsibility} if(defined $data->{editionresponsibility} && $data->{editionresponsibility} ne '');
            $biblioItem->{editionstatement} = $data->{editionstatement} if(defined $data->{editionstatement} && $data->{editionstatement} ne '');
            $biblioItem->{pages} = $data->{pages} if(defined $data->{pages} && $data->{pages} ne '');
            $biblioItem->{place} = $data->{place} if(defined $data->{place} && $data->{place} ne '');
            $biblioItem->{url} = $data->{url} if(defined $data->{url} && $data->{url} ne '');
            
            $biblioItem->store or die($DBI::errstr);
            
            Koha::Exceptions::ObjectNotCreated->throw unless $biblioItem;
            
            my $biblioitemnumber = $biblioItem->biblioitemnumber;
            
            $self->getLogger()->debug("createBiblioItem stored biblioitemnumber: ". $biblioItem->biblioitemnumber);

            if($biblioitemnumber){
                $id = $biblioitemnumber;
                @result = ($id, $data->{'selleridentifier'});
            }
            else{
                die('Biblioitemid not set after db save.')
            }   
        }
        else{
            die('Required params not set.');
        }
    }
    return @result;
}

sub createBiblioMetadata {  
    my $self = shift;
    my ($copyDetail, $itemDetail, $order, $biblio) = @_;
    my $result = 0;
    my $data = {};

    if($itemDetail->isa('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail') ){
        $data->{'biblio'} = $biblio;
        my $marc = $copyDetail->getMarcXml();
        utf8::decode($marc);
        $data->{'marcxml'} = $marc;
        $data->{'format'} = 'marcxml';
        $data->{'marcflavour'} = C4::Context->preference('marcflavour');

        my @paramsToValidate = ('biblio', 'marcxml');
        if($self->validate({'params', \@paramsToValidate , 'data', $data })){
        
            my $biblioMetadata = Koha::Biblio::Metadata->new(
                {
                    biblionumber        => $data->{biblio},
                    metadata         => $data->{marcxml},
                    format         => $data->{format},
                    schema     => $data->{marcflavour}
                }
            );
            
            $biblioMetadata->store or die($DBI::errstr);
            
            my $biblioMetadataid = $biblioMetadata->biblionumber;
            
            $self->getLogger()->debug("createBiblioMetadata stored biblio metadata for biblio " . $biblioMetadata->biblionumber);
            
            my $dbh = C4::Context->dbh;

            if($biblioMetadataid){
                $result = $biblioMetadataid;
            }
            else{
                die('Bibliometaid not set after db save.')
            } 
        }
        else{
            die('Required params not set.');
        }
    }
    return $result;
}



sub createItem {    
    my $self = shift;
    my ($copyDetail, $itemDetail, $order, $barcode, $biblio, $biblioitem) = @_;
    my $result = 0;
    my $data = {};

    if($itemDetail->isa('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail') ){
        $data->{'booksellerid'} = $order->getSellerId();
        $data->{'destinationlocation'} = $copyDetail->getBranchCode();
        $data->{'price'} = $itemDetail->getPriceFixedRPExcludingTax();
        $data->{'replacementprice'} = $data->{'price'};
        $data->{'timestamp'} = $order->getTimeStamp();
        $data->{'productform'} = $self->getItemProductForm($itemDetail->getProductForm(), $copyDetail->getLocation());
        $data->{'notes'} = $itemDetail->getNotes();
        $data->{'datecreated'} = $order->getDateCreated();
        $data->{'collectioncode'} = $copyDetail->getLocation();
        $data->{'biblio'} = $biblio;
        $data->{'biblioitem'} = $biblioitem;

        my $autoBarcodeType = C4::Context->preference("autoBarcode");
        my (%args, $nextnum, $scr);
        my $yaml = $self->barcodePrefixesFromPreference( C4::Context->preference("BarcodePrefix") );
        my @prefixes = grep { defined $_ && $_ ne '' } values %$yaml;

        ($args{date}) = strftime "%y%m%d", localtime;
        ($args{tag},$args{subfield})       =  $self->getMarcFromKohaFieldCompat("items.barcode");
        ($args{loctag},$args{locsubfield}) =  $self->getMarcFromKohaFieldCompat("items.homebranch");
        ($args{branchcode}) = $data->{'destinationlocation'};
        ($args{prefix}) = $yaml->{$data->{'destinationlocation'}} // $yaml->{'Default'};
        ($args{prefixes}) = \@prefixes;
        
        $self->getLogger()->debug("createItem destinationlocation: ". $data->{'destinationlocation'});

        $data->{"barcode"} = $self->generateBarcode(\%args, $autoBarcodeType);

        my @paramsToValidate = ('biblio', 'biblioitem', 'booksellerid', 'destinationlocation', 'price', 'replacementprice', 'productform', 'notes', 'datecreated', 'collectioncode');
        if($self->validate({'params', \@paramsToValidate , 'data', $data })){
            
        my $item = Koha::Item->new(
                {
                    biblionumber        => $data->{'biblio'},
                    biblioitemnumber          => $data->{'biblioitem'},
                    booksellerid       => $data->{'booksellerid'},
                    homebranch => $data->{'destinationlocation'},
                    replacementprice           => $data->{'replacementprice'},
                    timestamp            => $data->{'timestamp'},
                    itype               => $data->{'productform'},
                    coded_location_qualifier               => $data->{'notes'},
                    price          => $data->{'price'},
                    dateaccessioned                 => $data->{'datecreated'},
                    barcode          => $data->{'barcode'},
                    datelastseen               => $data->{'datecreated'},
                    notforloan    => -1,
                    holdingbranch      => $data->{'destinationlocation'},
                    location      => $data->{'collectioncode'},
                    permanent_location      => $data->{'collectioncode'}
                }
            )->store or die($DBI::errstr);  
            
            if($item->itemnumber){
                $self->getLogger()->info("createItem created item: ". $item->itemnumber);
                $result = $item->itemnumber;
            }
            else{
                die('Itemidnumber not set after db save.')
            }        
        }
        else{
             die('Required params not set.');
        }
    }
    return $result;
}

sub updateAqbudgetLog {
    my $self = shift;
    my ($copyDetail, $itemDetail, $order, $biblio) = @_;

    my $dbh = C4::Context->dbh;
    return 1 if !$self->_koha_suomi_spend_log_available($dbh);

    my $copyQty = $copyDetail->getCopyQuantity();
    my $totalAmount = $copyDetail->getFundMonetaryAmount() * $copyQty;

    my $monetaryamount = $itemDetail->getPriceFixedRPExcludingTax();
    my $timestamp = $order->getTimeStamp();
    my $tied = $order->getFileName();
    my $fundnumber = $copyDetail->getFundNumber();
    my $personname = $order->getPersonName();
    my $productform = $itemDetail->getProductForm();
    my $copyquantity = $copyQty;
    my $destinationlocation = $copyDetail->getBranchCode();
    my $collectioncode = $copyDetail->getLocation();

    my $spend_log_table = KOHA_SUOMI_SPEND_LOG_TABLE;
    my $stmnt = $dbh->prepare(qq{INSERT INTO $spend_log_table (monetary_amount,timestamp,origin,fund,account,itemtype,copy_quantity,total_amount,location,collection,biblionumber) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)});
    $stmnt->execute($monetaryamount,$timestamp,$tied,$fundnumber,$personname,$productform,$copyquantity,$totalAmount,$destinationlocation,$collectioncode,$biblio)
        or die( $dbh->errstr || 'Could not update aqbudgets_spend_log.' );

    return 1;
}

sub _koha_suomi_spend_log_available {
    my ( $self, $dbh ) = @_;

    return $self->{_koha_suomi_spend_log_available}
        if exists $self->{_koha_suomi_spend_log_available};

    my $available = $self->_table_exists( $dbh, KOHA_SUOMI_SPEND_LOG_TABLE ) ? 1 : 0;
    if ( !$available ) {
        $self->getLogger()->log('Skipping KohaSuomi aqbudgets_spend_log integration because the local table does not exist.');
    }

    $self->{_koha_suomi_spend_log_available} = $available;
    return $available;
}

sub getBookseller {
    my $self = shift;
    my ($order) = @_;
    my ( $san, $qualifier ) = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::VendorEdiAccount->identifier_from_values(
        $order->getVendorAssignedId(),
        $order->getBuyerAssignedId()
    );

    my $dbh = C4::Context->dbh;
    my $vendor = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::VendorEdiAccount->find_vendor(
        {
            dbh       => $dbh,
            san       => $san,
            qualifier => $qualifier,
        }
    );

    if ( $vendor->{status} ne 'found' ) {
        $self->getLogger()->warn( $vendor->{message} );
        die $vendor->{message} . "\n";
    }
    return $vendor->{vendor_id};
}

sub getProductForm {
    my $self = shift;
    my $productForm = $_[0];

    my $mapping = $self->_get_productform_mapping($productForm);
    return $self->_validate_mapped_productform( $productForm, $mapping->{productform}, 'productform' );
}

sub getItemProductForm {
    my $self = shift;
    my $productForm = $_[0];
    my $location = $_[1];

    my $mapping = $self->_get_productform_mapping($productForm);
    my $settings = $self->getConfig()->getSettings();
    my $productform_alternatives = $settings->{settings}->{productform_alternative_triggers} // '';
    my @productform_alternatives = grep { $_ ne '' } map {
        my $trigger = $_;
        $trigger =~ s/\A\s+|\s+\z//g;
        $trigger;
    } split( ',', $productform_alternatives );

    foreach my $pf_alternative_trigger (@productform_alternatives) {
        if ( defined $location && $location eq $pf_alternative_trigger ) {
            return $self->_validate_mapped_productform(
                $productForm,
                $mapping->{productform_alternative},
                "productform_alternative for location '$location'"
            );
        }
    }

    return $self->_validate_mapped_productform( $productForm, $mapping->{productform}, 'productform' );
}

sub _get_productform_mapping {
    my ( $self, $productForm ) = @_;

    die 'EDItX ProductForm is missing.' unless $productForm;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_map_productform_table();
    my $stmnt = $dbh->prepare("SELECT productform, productform_alternative FROM $map_productform_table WHERE onix_code = ?");
    $stmnt->execute($productForm) or die( $dbh->errstr || "Could not read ProductForm mapping for '$productForm'." );

    my $mapping = $stmnt->fetchrow_hashref();
    die "No Koha item type mapping found for EDItX ProductForm '$productForm'." unless $mapping;

    return $mapping;
}

sub _validate_mapped_productform {
    my ( $self, $productForm, $mapped_itemtype, $mapping_column ) = @_;

    die "EDItX ProductForm '$productForm' has no Koha item type in $mapping_column."
        unless defined $mapped_itemtype && $mapped_itemtype ne '';
    die "Mapped Koha item type '$mapped_itemtype' for EDItX ProductForm '$productForm' does not exist."
        unless $self->_itemtype_exists($mapped_itemtype);

    return $mapped_itemtype;
}

sub _itemtype_exists {
    my ( $self, $itemtype ) = @_;

    return unless $itemtype;

    my $dbh = C4::Context->dbh;
    my ($exists) = $dbh->selectrow_array( 'SELECT COUNT(*) FROM itemtypes WHERE itemtype = ?', undef, $itemtype );
    return $exists ? 1 : 0;
}

sub _table_exists {
    my ( $self, $dbh, $table ) = @_;

    return unless $table;

    my ($exists) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME = ?
        },
        undef,
        $table
    );
    return $exists ? 1 : 0;
}

sub validate {
    my $self = shift;
    my $values = $_[0];
    my ($params, $data, $param);
    my $result = 1;
    if(defined $values->{params}){
        $params = $values->{params};
    }

    if(defined $values->{data}){
        $data  = $values->{data};
    }

    foreach(@$params){
        $param = $_;

        if(!defined $data->{$param} || $data->{$param} eq ''){
            $self->getLogger()->logError("Required parameter: '\$$param' was not set or it was empty.",1);
            $result = 0;
        }
    }
    return $result;
}

sub getAuthoriser {
    my $self = shift;
    my $authoriser;
    my $settings = $self->getConfig()->getSettings();
    if(defined $settings->{settings}->{authoriser} ){
        $authoriser = $settings->{settings}->{authoriser};
    }
    return $authoriser;
}


1;

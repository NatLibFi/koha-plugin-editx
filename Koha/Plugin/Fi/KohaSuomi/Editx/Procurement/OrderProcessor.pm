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
use C4::Biblio qw( GetFrameworkCode GetMarcBiblio ModBiblio ModZebra );
use Koha::DateUtils;
use C4::Barcodes::ValueBuilder;
use utf8;
use List::MoreUtils qw(uniq);
use Data::Dumper;

use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor::Order;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor::Basket;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::MarcHelper;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;

use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::FinnaMaterialType;
use C4::Languages qw(getlanguage);

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

    my ($item, $copyDetail, $copyQty, $barCode, $biblio, $biblioitem, $isbn, $basketNumber, $bookseller, $itemId, $orderId);
    my $authoriser = $self->getAuthoriser();
    my $basketName = $order->getBasketName();
  
    $self->getLogger()->log("getAuthoriser: " . $authoriser);
    $self->getLogger()->log("getBasketName: " . $basketName);
    
    my (@copydetailstoadd, @itemstoadd, @orderstoadd, @bibliostoadd);

    foreach(@$itemDetails){
        $item = $_;
        my $copyDetails = $item->getCopyDetail();
        foreach(@$copyDetails){
            $copyDetail = $_;
            ($biblio, $biblioitem) = $self->getBiblioDatas($copyDetail, $item, $order);
            $self->getLogger()->log("getBiblioDatas biblio: ". $biblio); 
            $copyQty = $copyDetail->getCopyQuantity();
            if($copyQty > 0){
                $bookseller = $self->getBookseller($order);
                $basketNumber = $basketHelper->getBasket($bookseller, $authoriser, $basketName );
                
                $orderId = $orderCreator->createOrder($copyDetail, $item, $order, $biblio, $basketNumber);
                $self->getLogger()->log("createOrder orderId: " . $orderId);
                for(my $i = 0; $copyQty > $i; $i++ ){
                    $itemId = $self->createItem($copyDetail, $item, $order, $barCode, $biblio, $biblioitem);

                    $orderCreator->createOrderItem($itemId, $orderId);
                    
                }
                

                # $self->updateAqbudgetLog($copyDetail, $item, $order, $biblio);
                        
                # $self->getLogger()->log("Adding bibliographic record $biblio to Zebra queue.");
                        
                # ModZebra( $biblio, "specialUpdate", "biblioserver" );

                push @copydetailstoadd, $copyDetail;
                
                push @itemstoadd, $item;
                
                push @orderstoadd, $order;
                
                push @bibliostoadd, $biblio;
                
            }
        }
    }
    
    my $arr_size = @copydetailstoadd;
    
    $self->getLogger()->log("Updating aqbudgets ($arr_size items)...");
        
    for(my $i = 0; $i <= $arr_size -1; $i++){
         
        $self->updateAqbudgetLog($copydetailstoadd[$i], $itemstoadd[$i], $orderstoadd[$i], $bibliostoadd[$i]);
    }
    
    $self->getLogger()->log("Budgets updated.");
    
    #   by the words of Johanna's granny concerning her 2-bristled dishwasher brush: 'You never know when you might need to use it'
    #for(my $i = 0; $i <= $arr_size -1; $i++){
    #    
    #    ModZebra( $bibliostoadd[$i], "specialUpdate", "biblioserver" );
    #    $self->getLogger()->log("Added bibliographic record $bibliostoadd[$i] to Zebra queue.");
    #}

    $basketHelper->closeBasket($basketName);
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
        $self->getLogger()->log("createBiblioItem biblioitem: " . $bibitemdetails);
        
        $bibliometa = $self->createBiblioMetadata($copyDetail, $itemDetail, $order, $biblio);
        
        my $bibmeta = Data::Dumper::Dumper $bibliometa;
        $self->getLogger()->log("createBiblioMetadata bibliometa: " . $bibmeta);

        #my $marcBiblio = GetMarcBiblio($biblio);
        my $marcBiblio;
        # gives undef my $marcBiblio = C4::Biblio::GetMarcBiblio({ biblionumber => $biblio });
        eval { $marcBiblio = C4::Biblio::GetMarcBiblio({ biblionumber => $biblio }); };
        if ($@ || !$marcBiblio) {
            # here we do warn since catching an exception
            # means that the bib was found but failed
            # to be parsed
            $self->getLogger()->log($@);
            $self->getLogger()->log("GetMarcBiblio error retrieving biblio $biblio");
        }
            
        if(! $marcBiblio){
           die('Getting marcbiblio failed.');
        }
        if(! ModBiblio($marcBiblio, $biblio, '')){
           die('Modbiblio failed.');
        }
    }
    
    return ($biblio, $biblioitem);
}

sub getBiblioItemData {  
    my $self = shift;
    my ($copyDetail, $itemDetail, $order) = @_;
    my (@isbns, $ean, $publishercode, $editionresponsibility, $rows, $row, @result);
    my $isbns1 = $itemDetail->getIsbns();
    push @isbns, @$isbns1;
    my $isbns2 = $copyDetail->getIsbns();
    push @isbns, @$isbns2;
    @isbns = uniq @isbns;

    $ean = $copyDetail->getMarcStdIdentifier();
    $publishercode = $copyDetail->getMarcPublisherIdentifier();
    $editionresponsibility = $copyDetail->getMarcPublisher();

    if(@isbns){
        $rows = $self->getItemsByIsbns(@isbns);
    }

    if($ean && (!$rows || $rows->count <= 0)){
        $rows = $self->getItemByColumns({ ean =>$ean});
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

    if( ($autoBarcodeType eq 'preyyyymmincr' && $prefix) ){
        $barcode = $prefix.$date.$nextnum;
    } else {
        $barcode = "HANK_".$date.$nextnum;
    }

    return $barcode;
}

sub advanceBarcodeValue {  
    my ($self, $date, $prefixes) = @_;
    my $dbh = C4::Context->dbh;

    my $regex = sprintf "%s$date|" x @$prefixes, @$prefixes;
    $regex .= "HANK_$date";

    my $update_query = "UPDATE sequences set item_barcode_nextval = item_barcode_nextval+1";
    my $query = 'SELECT MAX(CAST(SUBSTRING(barcode,-5) AS signed)) from items where barcode REGEXP "'.$regex.'"';
    my $stmnt = $dbh->prepare($query);
    $stmnt->execute();

    while (my ($count)= $stmnt->fetchrow_array) {
        if(!$count || $count == 9999){
            $update_query = "UPDATE sequences set item_barcode_nextval = 1";
        }
    }

    $stmnt = $dbh->prepare($update_query);
    $stmnt->execute();
}

sub getBarcodeValue {  
    my $self = shift;

    my $dbh = C4::Context->dbh;
    my $stmnt = $dbh->prepare("SELECT max(item_barcode_nextval) from sequences");
    $stmnt->execute();

    my $nextnum = sprintf("%0*d", "5",$stmnt->fetchrow_array());

    return $nextnum;
}

sub getItemsByIsbns {   
    my $self = shift;
    my @isbnArray = $_[0];
    my $resultSet = $self->getSchema()->resultset(Koha::Biblioitem->_type());
    my $result = -1;

    if(@isbnArray > 0){
        $result = $resultSet->search({'isbn' => {'in' => @isbnArray}},{ select => [qw/isbn biblionumber biblioitemnumber/] });
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
            $self->getLogger()->log("createBiblio stored biblionumber: ". $result);         
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
            
            $self->getLogger()->log("createBiblioItem stored biblioitemnumber: ". $biblioItem->biblioitemnumber);

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
            
            $self->getLogger()->log("createBiblioMetadata stored biblio metadata for biblio " . $biblioMetadata->biblionumber);
            
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
    my $fundnr = $copyDetail->getFundNumber();

    if($itemDetail->isa('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail') ){
        $data->{'booksellerid'} = $order->getSellerId();
        $data->{'destinationlocation'} = $copyDetail->getBranchCode();
        $data->{'price'} = $itemDetail->getPriceFixedRPExcludingTax();
        $data->{'replacementprice'} = $itemDetail->getPriceFixedRPExcludingTax();
        $data->{'timestamp'} = $order->getTimeStamp();
        $data->{'productform'} = $self->getItemProductForm($itemDetail->getProductForm(), $fundnr);
        $data->{'notes'} = $itemDetail->getNotes();
        $data->{'datecreated'} = $order->getDateCreated();
        $data->{'collectioncode'} = $copyDetail->getLocation();
        $data->{'biblio'} = $biblio;
        $data->{'biblioitem'} = $biblioitem;

        my $autoBarcodeType = C4::Context->preference("autoBarcode");
        my (%args, $nextnum, $scr);
        my $branchPrefixes = C4::Context->preference("BarcodePrefix");
        my $yaml = YAML::XS::Load(
                        Encode::encode(
                            'UTF-8',
                            $branchPrefixes,
                            Encode::FB_CROAK
                        )
        );
        my @prefixes = values %$yaml;

        ($args{date}) = strftime "%y%m%d", localtime;
        ($args{tag},$args{subfield})       =  C4::Biblio::GetMarcFromKohaField("items.barcode", '');
        ($args{loctag},$args{locsubfield}) =  C4::Biblio::GetMarcFromKohaField("items.homebranch", '');
        ($args{branchcode}) = $data->{'destinationlocation'};
        ($args{prefix}) = $yaml->{$data->{'destinationlocation'}} || $yaml->{'Default'};
        ($args{prefixes}) = \@prefixes;

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
                $self->getLogger()->log("createItem created item: ". $item->itemnumber);
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

    my $dbh = C4::Context->dbh;
    my $stmnt = $dbh->prepare(qq{INSERT INTO aqbudgets_spend_log (monetary_amount,timestamp,origin,fund,account,itemtype,copy_quantity,total_amount,location,collection,biblionumber) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)});
    $stmnt->execute($monetaryamount,$timestamp,$tied,$fundnumber,$personname,$productform,$copyquantity,$totalAmount,$destinationlocation,$collectioncode,$biblio) or die($DBI::errstr);
}

sub getBookseller {
    my $self = shift;
    my ($order) = @_;
    my ($san, $qualifier, $bookseller) = (0, 91, 0);

    $san = $order->getVendorAssignedId();
    if (!$san) {
        $san = $order->getBuyerAssignedId();
        $qualifier = 92;
    }

    my $dbh = C4::Context->dbh;
    my $stmnt = $dbh->prepare("SELECT vendor_id FROM vendor_edi_accounts WHERE san = ? AND id_code_qualifier=? AND transport='FILE' AND orders_enabled='1'");
    $stmnt->execute($san, $qualifier) or die($DBI::errstr);
    $bookseller = $stmnt->fetchrow_array();

    if(!$bookseller){
        if ($san) {
            $self->getLogger()->log("No vendor for SAN $san (qualifier $qualifier) in vendor_edi_accounts.");
            $self->getLogger()->log("No vendor for SAN $san (qualifier $qualifier) in vendor_edi_accounts.");
        }
        else {
            $self->getLogger()->log("No vendor in shipment notice.");
            $self->getLogger()->log("No vendor in shipment notice.");
        }
        die();
    }
    return $bookseller;
}

sub getProductForm {
    my $self = shift;
    my $productForm = $_[0];
    my $result;

    if($productForm){       
        my $dbh = C4::Context->dbh;
        my $stmnt = $dbh->prepare("SELECT max(productform) from map_productform where onix_code = ?");
        $stmnt->execute($productForm) or die($DBI::errstr);
        $result = $stmnt->fetchrow_array();
    }

    if($result){
        $productForm = $result;
    }
    return $productForm;
}

sub getItemProductForm {
    my $self = shift;
    my $productForm = $_[0];
    my $productFormAlternative;
    my $fundnr = $_[1];
    my $result;

    if($productForm){

        my $dbh = C4::Context->dbh;
        my $stmnt = $dbh->prepare("SELECT productform_alternative from map_productform where onix_code = ?");
        $stmnt->execute($productForm) or die($DBI::errstr);
        $result = $stmnt->fetchrow_array();

        if($result){
            $productFormAlternative = $result;

            my $settings = $self->getConfig()->getSettings();
            if(defined $settings->{settings}->{productform_alternative_triggers} ){
                my $productform_alternatives = $settings->{settings}->{productform_alternative_triggers};

                my @productform_alternatives = split(',', $productform_alternatives);

                my $pf_alternative_trigger;

                foreach $pf_alternative_trigger (@productform_alternatives) {
                    
                    my $fundnr_regexedloc = $fundnr;
                    my $n = 4;
                    $fundnr_regexedloc =~ s/\d{$n}$//; #remove last $n digits
                    my $matchlen = length($pf_alternative_trigger);
                    $fundnr_regexedloc = substr $fundnr_regexedloc, -($matchlen);

                    if($fundnr_regexedloc eq $pf_alternative_trigger)
                    {
                        return $productFormAlternative;
                    }
                }
            }
        }

        $stmnt = $dbh->prepare("SELECT productform from map_productform where onix_code = ?");
        $stmnt->execute($productForm) or die($DBI::errstr);
        $result = $stmnt->fetchrow_array();

        if($result){
            $productForm = $result;
            return $productForm;
        }
    }
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

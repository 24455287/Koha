package C4::Accounts;

# Copyright 2000-2002 Katipo Communications
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.


use strict;
#use warnings; FIXME - Bug 2505
use C4::Context;
use C4::Stats;
use C4::Members;
use C4::Circulation qw(ReturnLostItem);
use C4::Log qw(logaction);
use Koha::Account;
use Koha::Account::Lines;

use Data::Dumper qw(Dumper);

use vars qw(@ISA @EXPORT);

BEGIN {
    require Exporter;
    @ISA    = qw(Exporter);
    @EXPORT = qw(
      &manualinvoice
      &getnextacctno
      &getcharges
      &ModNote
      &getcredits
      &getrefunds
      &chargelostitem
      &ReversePayment
      &purge_zero_balance_fees
    );
}

=head1 NAME

C4::Accounts - Functions for dealing with Koha accounts

=head1 SYNOPSIS

use C4::Accounts;

=head1 DESCRIPTION

The functions in this module deal with the monetary aspect of Koha,
including looking up and modifying the amount of money owed by a
patron.

=head1 FUNCTIONS

=head2 getnextacctno

  $nextacct = &getnextacctno($borrowernumber);

Returns the next unused account number for the patron with the given
borrower number.

=cut

#'
# FIXME - Okay, so what does the above actually _mean_?
sub getnextacctno {
    my ($borrowernumber) = shift or return;
    my $sth = C4::Context->dbh->prepare(
        "SELECT accountno+1 FROM accountlines
            WHERE    (borrowernumber = ?)
            ORDER BY accountno DESC
            LIMIT 1"
    );
    $sth->execute($borrowernumber);
    return ($sth->fetchrow || 1);
}

=head2 fixaccounts (removed)

  &fixaccounts($accountlines_id, $borrowernumber, $accountnumber, $amount);

#'
# FIXME - I don't understand what this function does.
sub fixaccounts {
    my ( $accountlines_id, $borrowernumber, $accountno, $amount ) = @_;
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare(
        "SELECT * FROM accountlines WHERE accountlines_id=?"
    );
    $sth->execute( $accountlines_id );
    my $data = $sth->fetchrow_hashref;

    # FIXME - Error-checking
    my $diff        = $amount - $data->{'amount'};
    my $outstanding = $data->{'amountoutstanding'} + $diff;
    $sth->finish;

    $dbh->do(<<EOT);
        UPDATE  accountlines
        SET     amount = '$amount',
                amountoutstanding = '$outstanding'
        WHERE   accountlines_id = $accountlines_id
EOT
	# FIXME: exceedingly bad form.  Use prepare with placholders ("?") in query and execute args.
}

=cut

sub chargelostitem{
# lost ==1 Lost, lost==2 longoverdue, lost==3 lost and paid for
# FIXME: itemlost should be set to 3 after payment is made, should be a warning to the interface that
# a charge has been added
# FIXME : if no replacement price, borrower just doesn't get charged?
    my $dbh = C4::Context->dbh();
    my ($borrowernumber, $itemnumber, $amount, $description) = @_;

    # first make sure the borrower hasn't already been charged for this item
    my $sth1=$dbh->prepare("SELECT * from accountlines
    WHERE borrowernumber=? AND itemnumber=? and accounttype='L'");
    $sth1->execute($borrowernumber,$itemnumber);
    my $existing_charge_hashref=$sth1->fetchrow_hashref();

    # OK, they haven't
    unless ($existing_charge_hashref) {
        my $manager_id = 0;
        $manager_id = C4::Context->userenv->{'number'} if C4::Context->userenv;
        # This item is on issue ... add replacement cost to the borrower's record and mark it returned
        #  Note that we add this to the account even if there's no replacement price, allowing some other
        #  process (or person) to update it, since we don't handle any defaults for replacement prices.
        my $accountno = getnextacctno($borrowernumber);
        my $sth2=$dbh->prepare("INSERT INTO accountlines
        (borrowernumber,accountno,date,amount,description,accounttype,amountoutstanding,itemnumber,manager_id)
        VALUES (?,?,now(),?,?,'L',?,?,?)");
        $sth2->execute($borrowernumber,$accountno,$amount,
        $description,$amount,$itemnumber,$manager_id);

        if ( C4::Context->preference("FinesLog") ) {
            logaction("FINES", 'CREATE', $borrowernumber, Dumper({
                action            => 'create_fee',
                borrowernumber    => $borrowernumber,
                accountno         => $accountno,
                amount            => $amount,
                amountoutstanding => $amount,
                description       => $description,
                accounttype       => 'L',
                itemnumber        => $itemnumber,
                manager_id        => $manager_id,
            }));
        }

    }
}

=head2 manualinvoice

  &manualinvoice($borrowernumber, $itemnumber, $description, $type,
                 $amount, $note);

C<$borrowernumber> is the patron's borrower number.
C<$description> is a description of the transaction.
C<$type> may be one of C<CS>, C<CB>, C<CW>, C<CF>, C<CL>, C<N>, C<L>,
or C<REF>.
C<$itemnumber> is the item involved, if pertinent; otherwise, it
should be the empty string.

=cut

#'
# FIXME: In Koha 3.0 , the only account adjustment 'types' passed to this function
# are:
# 		'C' = CREDIT
# 		'FOR' = FORGIVEN  (Formerly 'F', but 'F' is taken to mean 'FINE' elsewhere)
# 		'N' = New Card fee
# 		'F' = Fine
# 		'A' = Account Management fee
# 		'M' = Sundry
# 		'L' = Lost Item
#

sub manualinvoice {
    my ( $borrowernumber, $itemnum, $desc, $type, $amount, $note ) = @_;
    my $manager_id = 0;
    $manager_id = C4::Context->userenv->{'number'} if C4::Context->userenv;
    my $dbh      = C4::Context->dbh;
    my $notifyid = 0;
    my $insert;
    my $accountno  = getnextacctno($borrowernumber);
    my $amountleft = $amount;

    if (   ( $type eq 'L' )
        or ( $type eq 'F' )
        or ( $type eq 'A' )
        or ( $type eq 'N' )
        or ( $type eq 'M' ) )
    {
        $notifyid = 1;
    }

    if ( $itemnum ) {
        $desc .= ' ' . $itemnum;
        my $sth = $dbh->prepare(
            'INSERT INTO  accountlines
                        (borrowernumber, accountno, date, amount, description, accounttype, amountoutstanding, itemnumber,notify_id, note, manager_id)
        VALUES (?, ?, now(), ?,?, ?,?,?,?,?,?)');
     $sth->execute($borrowernumber, $accountno, $amount, $desc, $type, $amountleft, $itemnum,$notifyid, $note, $manager_id) || return $sth->errstr;
  } else {
    my $sth=$dbh->prepare("INSERT INTO  accountlines
            (borrowernumber, accountno, date, amount, description, accounttype, amountoutstanding,notify_id, note, manager_id)
            VALUES (?, ?, now(), ?, ?, ?, ?,?,?,?)"
        );
        $sth->execute( $borrowernumber, $accountno, $amount, $desc, $type,
            $amountleft, $notifyid, $note, $manager_id );
    }

    if ( C4::Context->preference("FinesLog") ) {
        logaction("FINES", 'CREATE',$borrowernumber,Dumper({
            action            => 'create_fee',
            borrowernumber    => $borrowernumber,
            accountno         => $accountno,
            amount            => $amount,
            description       => $desc,
            accounttype       => $type,
            amountoutstanding => $amountleft,
            notify_id         => $notifyid,
            note              => $note,
            itemnumber        => $itemnum,
            manager_id        => $manager_id,
        }));
    }

    return 0;
}

sub getcharges {
	my ( $borrowerno, $timestamp, $accountno ) = @_;
	my $dbh        = C4::Context->dbh;
	my $timestamp2 = $timestamp - 1;
	my $query      = "";
	my $sth = $dbh->prepare(
			"SELECT * FROM accountlines WHERE borrowernumber=? AND accountno = ?"
          );
	$sth->execute( $borrowerno, $accountno );
	
    my @results;
    while ( my $data = $sth->fetchrow_hashref ) {
		push @results,$data;
	}
    return (@results);
}

sub ModNote {
    my ( $accountlines_id, $note ) = @_;
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare('UPDATE accountlines SET note = ? WHERE accountlines_id = ?');
    $sth->execute( $note, $accountlines_id );
}

sub getcredits {
	my ( $date, $date2 ) = @_;
	my $dbh = C4::Context->dbh;
	my $sth = $dbh->prepare(
			        "SELECT * FROM accountlines,borrowers
      WHERE amount < 0 AND accounttype not like 'Pay%' AND accountlines.borrowernumber = borrowers.borrowernumber
	  AND timestamp >=TIMESTAMP(?) AND timestamp < TIMESTAMP(?)"
      );  

    $sth->execute( $date, $date2 );                                                                                                              
    my @results;          
    while ( my $data = $sth->fetchrow_hashref ) {
		$data->{'date'} = $data->{'timestamp'};
		push @results,$data;
	}
    return (@results);
} 


sub getrefunds {
	my ( $date, $date2 ) = @_;
	my $dbh = C4::Context->dbh;
	
	my $sth = $dbh->prepare(
			        "SELECT *,timestamp AS datetime                                                                                      
                  FROM accountlines,borrowers
                  WHERE (accounttype = 'REF'
					  AND accountlines.borrowernumber = borrowers.borrowernumber
					                  AND date  >=?  AND date  <?)"
    );

    $sth->execute( $date, $date2 );

    my @results;
    while ( my $data = $sth->fetchrow_hashref ) {
		push @results,$data;
		
	}
    return (@results);
}

sub ReversePayment {
    my ( $accountlines_id ) = @_;
    my $dbh = C4::Context->dbh;

    my $sth = $dbh->prepare('SELECT * FROM accountlines WHERE accountlines_id = ?');
    $sth->execute( $accountlines_id );
    my $row = $sth->fetchrow_hashref();
    my $amount_outstanding = $row->{'amountoutstanding'};

    if ( $amount_outstanding <= 0 ) {
        $sth = $dbh->prepare('UPDATE accountlines SET amountoutstanding = amount * -1, description = CONCAT( description, " Reversed -" ) WHERE accountlines_id = ?');
        $sth->execute( $accountlines_id );
    } else {
        $sth = $dbh->prepare('UPDATE accountlines SET amountoutstanding = 0, description = CONCAT( description, " Reversed -" ) WHERE accountlines_id = ?');
        $sth->execute( $accountlines_id );
    }

    if ( C4::Context->preference("FinesLog") ) {
        my $manager_id = 0;
        $manager_id = C4::Context->userenv->{'number'} if C4::Context->userenv;

        if ( $amount_outstanding <= 0 ) {
            $row->{'amountoutstanding'} *= -1;
        } else {
            $row->{'amountoutstanding'} = '0';
        }
        $row->{'description'} .= ' Reversed -';
        logaction("FINES", 'MODIFY', $row->{'borrowernumber'}, Dumper({
            action                => 'reverse_fee_payment',
            borrowernumber        => $row->{'borrowernumber'},
            old_amountoutstanding => $row->{'amountoutstanding'},
            new_amountoutstanding => 0 - $amount_outstanding,,
            accountlines_id       => $row->{'accountlines_id'},
            accountno             => $row->{'accountno'},
            manager_id            => $manager_id,
        }));

    }

}

=head2 purge_zero_balance_fees

  purge_zero_balance_fees( $days );

Delete accountlines entries where amountoutstanding is 0 or NULL which are more than a given number of days old.

B<$days> -- Zero balance fees older than B<$days> days old will be deleted.

B<Warning:> Because fines and payments are not linked in accountlines, it is
possible for a fine to be deleted without the accompanying payment,
or vise versa. This won't affect the account balance, but might be
confusing to staff.

=cut

sub purge_zero_balance_fees {
    my $days  = shift;
    my $count = 0;

    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare(
        q{
            DELETE FROM accountlines
            WHERE date < date_sub(curdate(), INTERVAL ? DAY)
              AND ( amountoutstanding = 0 or amountoutstanding IS NULL );
        }
    );
    $sth->execute($days) or die $dbh->errstr;
}

END { }    # module clean-up code here (global destructor)

1;
__END__

=head1 SEE ALSO

DBI(3)

=cut


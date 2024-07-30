<!-- Sedo Code -->
<?php

function getTopDomains() {
    $lines = file('https://sedo.com/txt/topdomains_e.txt');
    $topDomains = array();
    foreach($lines as $line) {
        array_push($topDomains, str_getcsv($line, '~'));
    }

    shuffle($topDomains);
    return array_slice($topDomains, 0, 5);
}

$topDomains = getTopDomains();
?>

<table style="border: 0 none; background-color: #e0e8ef; border-collapse: separate; border-spacing: 1px">
    <tr>
        <th colspan="2" style="background-color: #e0e8ef; font-size:16px; font-weight:600; padding: 5px 10px;">
            TOP Domains
        </th>
    </tr>

    <?php foreach($topDomains as $domain) { ?>
    <tr>
        <td style="background-color: #fafafa; padding: 5px 10px;">
            <a href="https://sedo.com/search/details/?campaignId=332921&language=e&domain=<?php echo $domain[0]; ?>" target="_blank" style="font-size:14px;">
                <?php echo $domain[0]; ?>
            </a>
        </td>
        <td style="background-color: #fff; font-size:14px; padding: 5px 10px;"><?php echo $domain[1]; ?></td>
    </tr>
    <?php } ?>
</table>
<!-- Sedo Code Ende -->
